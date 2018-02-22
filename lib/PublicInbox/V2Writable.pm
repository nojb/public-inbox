# Copyright (C) 2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# This interface wraps and mimics PublicInbox::Import
package PublicInbox::V2Writable;
use strict;
use warnings;
use Fcntl qw(:flock :DEFAULT);
use PublicInbox::SearchIdxPart;
use PublicInbox::SearchIdxThread;
use PublicInbox::MIME;
use PublicInbox::Git;
use PublicInbox::Import;
use Email::MIME::ContentType;
$Email::MIME::ContentType::STRICT_PARAMS = 0;

# an estimate of the post-packed size to the raw uncompressed size
my $PACKING_FACTOR = 0.4;

# assume 2 cores if GNU nproc(1) is not available
my $NPROC = int($ENV{NPROC} || `nproc 2>/dev/null` || 2);

sub new {
	my ($class, $v2ibx, $creat) = @_;
	my $dir = $v2ibx->{mainrepo} or die "no mainrepo in inbox\n";
	unless (-d $dir) {
		if ($creat) {
			require File::Path;
			File::Path::mkpath($dir);
		} else {
			die "$dir does not exist\n";
		}
	}
	my $self = {
		-inbox => $v2ibx,
		im => undef, #  PublicInbox::Import
		xap_rw => undef, # PublicInbox::V2SearchIdx
		xap_ro => undef,
		partitions => $NPROC,
		transact_bytes => 0,
		# limit each repo to 1GB or so
		rotate_bytes => int((1024 * 1024 * 1024) / $PACKING_FACTOR),
	};
	bless $self, $class
}

# returns undef on duplicate or spam
# mimics Import::add and wraps it for v2
sub add {
	my ($self, $mime, $check_cb) = @_;
	my $existing = $self->lookup_content($mime);

	if ($existing) {
		return undef if $existing->type eq 'mail'; # duplicate
	}

	my $im = $self->importer;

	# im->add returns undef if check_cb fails
	my $cmt = $im->add($mime, $check_cb) or return;
	$cmt = $im->get_mark($cmt);
	my $oid = $im->{last_object_id};
	my ($len, $msgref) = @{$im->{last_object}};

	$self->idx_init;
	my $num = $self->{all}->index_mm($mime);
	my $nparts = $self->{partitions};
	my $part = $num % $nparts;
	my $idx = $self->idx_part($part);
	$idx->index_raw($len, $msgref, $num, $oid);
	my $n = $self->{transact_bytes} += $len;
	if ($n > (PublicInbox::SearchIdx::BATCH_BYTES * $nparts)) {
		$self->checkpoint;
	}

	$mime;
}

sub idx_part {
	my ($self, $part) = @_;
	$self->{idx_parts}->[$part];
}

sub idx_init {
	my ($self) = @_;
	return if $self->{idx_parts};
	# first time initialization:
	my $all = $self->{all} =
		PublicInbox::SearchIdxThread->new($self->{-inbox});

	# need to create all parts before initializing msgmap FD
	my $max = $self->{partitions} - 1;
	my $idx = $self->{idx_parts} = [];
	for my $i (0..$max) {
		push @$idx, PublicInbox::SearchIdxPart->new($self, $i, $all);
	}
	$all->_msgmap_init->{dbh}->begin_work;
}

sub remove {
	my ($self, $mime, $msg) = @_;
	my $existing = $self->lookup_content($mime) or return;

	# don't touch ghosts or already junked messages
	return unless $existing->type eq 'mail';

	# always write removals to the current (latest) git repo since
	# we process chronologically
	my $im = $self->importer;
	my ($cmt, undef) = $im->remove($mime, $msg);
	$cmt = $im->get_mark($cmt);
	$self->unindex_msg($existing, $cmt);
}

sub done {
	my ($self) = @_;
	my $im = $self->{im};
	$im->done if $im; # PublicInbox::Import::done
	$self->searchidx_checkpoint(0);
}

sub checkpoint {
	my ($self) = @_;
	my $im = $self->{im};
	$im->checkpoint if $im; # PublicInbox::Import::checkpoint
	$self->searchidx_checkpoint(1);
}

sub searchidx_checkpoint {
	my ($self, $more) = @_;

	# order matters, we can only close {all} after all partitions
	# are done because the partitions also write to {all}

	if (my $parts = $self->{idx_parts}) {
		foreach my $idx (@$parts) {
			$idx->remote_commit;
			$idx->remote_close unless $more;
		}
		delete $self->{idx_parts} unless $more;
	}

	if (my $all = $self->{all}) {
		$all->{mm}->{dbh}->commit;
		if ($more) {
			$all->{mm}->{dbh}->begin_work;
		}
		$all->remote_commit;
		$all->remote_close unless $more;
		delete $self->{all} unless $more;
	}
	$self->{transact_bytes} = 0;
}

sub git_init {
	my ($self, $new) = @_;
	my $pfx = "$self->{-inbox}->{mainrepo}/git";
	my $git_dir = "$pfx/$new.git";
	die "$git_dir exists\n" if -e $git_dir;
	my @cmd = (qw(git init --bare -q), $git_dir);
	PublicInbox::Import::run_die(\@cmd);
	@cmd = (qw/git config/, "--file=$git_dir/config",
			'repack.writeBitmaps', 'true');
	PublicInbox::Import::run_die(\@cmd);

	my $all = "$self->{-inbox}->{mainrepo}/all.git";
	unless (-d $all) {
		@cmd = (qw(git init --bare -q), $all);
		PublicInbox::Import::run_die(\@cmd);
	}

	my $alt = "$all/objects/info/alternates";
	my $new_obj_dir = "../../git/$new.git/objects";
	my %alts;
	if (-e $alt) {
		open(my $fh, '<', $alt) or die "open < $alt: $!\n";
		%alts = map { chomp; $_ => 1 } (<$fh>);
	}
	return $git_dir if $alts{$new_obj_dir};
	open my $fh, '>>', $alt or die "open >> $alt: $!\n";
	print $fh "$new_obj_dir\n" or die "print >> $alt: $!\n";
	close $fh or die "close $alt: $!\n";
	$git_dir
}

sub importer {
	my ($self) = @_;
	my $im = $self->{im};
	if ($im) {
		if ($im->{bytes_added} < $self->{rotate_bytes}) {
			return $im;
		} else {
			$self->{im} = undef;
			$im->done;
			$self->searchidx_checkpoint(1);
			$im = undef;
			my $git_dir = $self->git_init(++$self->{max_git});
			my $git = PublicInbox::Git->new($git_dir);
			return $self->import_init($git, 0);
		}
	}
	my $latest;
	my $max = -1;
	my $new = 0;
	my $pfx = "$self->{-inbox}->{mainrepo}/git";
	if (-d $pfx) {
		foreach my $git_dir (glob("$pfx/*.git")) {
			$git_dir =~ m!/(\d+)\.git\z! or next;
			my $n = $1;
			if ($n > $max) {
				$max = $n;
				$latest = $git_dir;
			}
		}
	}
	if (defined $latest) {
		my $git = PublicInbox::Git->new($latest);
		my $packed_bytes = $git->packed_bytes;
		if ($packed_bytes >= $self->{rotate_bytes}) {
			$new = $max + 1;
		} else {
			$self->{max_git} = $max;
			return $self->import_init($git, $packed_bytes);
		}
	}
	$self->{max_git} = $new;
	$latest = $self->git_init($new);
	$self->import_init(PublicInbox::Git->new($latest), 0);
}

sub import_init {
	my ($self, $git, $packed_bytes) = @_;
	my $im = PublicInbox::Import->new($git, undef, undef, $self->{-inbox});
	$im->{bytes_added} = int($packed_bytes / $PACKING_FACTOR);
	$im->{want_object_id} = 1;
	$im->{ssoma_lock} = 0;
	$im->{path_type} = 'v2';
	$self->{im} = $im;
}

sub lookup_content {
	undef # TODO
}

1;
