# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Local storage (cache/memo) for lei(1), suitable for personal/private
# mail iff on encrypted device/FS.  Based on v2, but only deduplicates
# based on git OID.
#
# for xref3, the following are constant: $eidx_key = '.', $xnum = -1
package PublicInbox::LeiStore;
use strict;
use v5.10.1;
use parent qw(PublicInbox::Lock PublicInbox::IPC);
use PublicInbox::SearchIdx qw(crlf_adjust);
use PublicInbox::ExtSearchIdx;
use PublicInbox::Import;
use PublicInbox::InboxWritable;
use PublicInbox::V2Writable;
use PublicInbox::ContentHash qw(content_hash);
use PublicInbox::MID qw(mids);
use PublicInbox::LeiSearch;
use List::Util qw(max);

sub new {
	my (undef, $dir, $opt) = @_;
	my $eidx = PublicInbox::ExtSearchIdx->new($dir, $opt);
	my $self = bless { priv_eidx => $eidx }, __PACKAGE__;
	if ($opt->{creat}) {
		PublicInbox::SearchIdx::load_xapian_writable();
		eidx_init($self);
	}
	$self;
}

sub git { $_[0]->{priv_eidx}->git } # read-only

sub packing_factor { $PublicInbox::V2Writable::PACKING_FACTOR }

sub rotate_bytes {
	$_[0]->{rotate_bytes} // ((1024 * 1024 * 1024) / $_[0]->packing_factor)
}

sub git_pfx { "$_[0]->{priv_eidx}->{topdir}/local" };

sub git_epoch_max  {
	my ($self) = @_;
	if (opendir(my $dh, $self->git_pfx)) {
		max(map {
			substr($_, 0, -4) + 0; # drop ".git" suffix
		} grep(/\A[0-9]+\.git\z/, readdir($dh))) // 0;
	} else {
		$!{ENOENT} ? 0 : die("opendir ${\$self->git_pfx}: $!\n");
	}
}

sub git_ident ($) {
	my ($git) = @_;
	chomp(my $i = $git->qx(qw(var GIT_COMMITTER_IDENT)));
	warn "$git->{git_dir} GIT_COMMITTER_IDENT failed\n" if $?;
	$i =~ /\A(.+) <([^>]+)> [0-9]+ [-\+]?[0-9]+$/ ? ($1, $2) :
		('lei user', 'x@example.com')
}

sub importer {
	my ($self) = @_;
	my $max;
	my $im = $self->{im};
	if ($im) {
		return $im if $im->{bytes_added} < $self->rotate_bytes;

		delete $self->{im};
		$im->done;
		undef $im;
		$self->checkpoint;
		$max = $self->git_epoch_max + 1;
	}
	my $pfx = $self->git_pfx;
	$max //= $self->git_epoch_max;
	while (1) {
		my $latest = "$pfx/$max.git";
		my $old = -e $latest;
		PublicInbox::Import::init_bare($latest);
		my $git = PublicInbox::Git->new($latest);
		$git->qx(qw(config core.sharedRepository 0600)) if !$old;
		my $packed_bytes = $git->packed_bytes;
		my $unpacked_bytes = $packed_bytes / $self->packing_factor;
		if ($unpacked_bytes >= $self->rotate_bytes) {
			$max++;
			next;
		}
		my ($n, $e) = git_ident($git);
		$self->{im} = $im = PublicInbox::Import->new($git, $n, $e);
		$im->{bytes_added} = int($packed_bytes / $self->packing_factor);
		$im->{lock_path} = undef;
		$im->{path_type} = 'v2';
		return $im;
	}
}

sub search {
	PublicInbox::LeiSearch->new($_[0]->{priv_eidx}->{topdir});
}

sub eidx_init {
	my ($self) = @_;
	my $eidx = $self->{priv_eidx};
	$eidx->idx_init({-private => 1});
	$eidx;
}

sub _docids_for ($$) {
	my ($self, $eml) = @_;
	my %docids;
	my $chash = content_hash($eml);
	my $eidx = eidx_init($self);
	my $oidx = $eidx->{oidx};
	my $im = $self->{im};
	for my $mid (@{mids($eml)}) {
		my ($id, $prev);
		while (my $cur = $oidx->next_by_mid($mid, \$id, \$prev)) {
			my $oid = $cur->{blob};
			my $docid = $cur->{num};
			my $bref = $im ? $im->cat_blob($oid) : undef;
			$bref //= $eidx->git->cat_file($oid) // do {
				warn "W: $oid (#$docid) <$mid> not found\n";
				next;
			};
			local $self->{current_info} = $oid;
			my $x = PublicInbox::Eml->new($bref);
			$docids{$docid} = $docid if content_hash($x) eq $chash;
		}
	}
	sort { $a <=> $b } values %docids;
}

sub set_eml_keywords {
	my ($self, $eml, @kw) = @_;
	my $eidx = eidx_init($self);
	my @docids = _docids_for($self, $eml);
	for my $docid (@docids) {
		$eidx->idx_shard($docid)->shard_set_keywords($docid, @kw);
	}
	\@docids;
}

sub add_eml_keywords {
	my ($self, $eml, @kw) = @_;
	my $eidx = eidx_init($self);
	my @docids = _docids_for($self, $eml);
	for my $docid (@docids) {
		$eidx->idx_shard($docid)->shard_add_keywords($docid, @kw);
	}
	\@docids;
}

sub remove_eml_keywords {
	my ($self, $eml, @kw) = @_;
	my $eidx = eidx_init($self);
	my @docids = _docids_for($self, $eml);
	for my $docid (@docids) {
		$eidx->idx_shard($docid)->shard_remove_keywords($docid, @kw);
	}
	\@docids;
}

# cf: https://doc.dovecot.org/configuration_manual/mail_location/mbox/
my %status2kw = (F => 'flagged', A => 'answered', R => 'seen', T => 'draft');
# O (old/non-recent), and D (deleted) aren't in JMAP,
# so probably won't be supported by us.
sub mbox_keywords {
	my $eml = $_[-1];
	my $s = "@{[$eml->header_raw('X-Status'),$eml->header_raw('Status')]}";
	my %kw;
	$s =~ s/([FART])/$kw{$status2kw{$1}} = 1/sge;
	sort(keys %kw);
}

# cf: https://cr.yp.to/proto/maildir.html
my %c2kw = ('D' => 'draft', F => 'flagged', R => 'answered', S => 'seen');
sub maildir_keywords {
	$_[-1] =~ /:2,([A-Z]+)\z/i ?
		sort(map { $c2kw{$_} // () } split(//, $1)) : ();
}

sub add_eml {
	my ($self, $eml, @kw) = @_;
	my $eidx = eidx_init($self);
	my $oidx = $eidx->{oidx};
	my $smsg = bless { -oidx => $oidx }, 'PublicInbox::Smsg';
	my $im = $self->importer;
	$im->add($eml, undef, $smsg) or return; # duplicate returns undef
	my $msgref = delete $smsg->{-raw_email};
	$smsg->{bytes} = $smsg->{raw_bytes} + crlf_adjust($$msgref);

	local $self->{current_info} = $smsg->{blob};
	if (my @docids = _docids_for($self, $eml)) {
		for my $docid (@docids) {
			my $idx = $eidx->idx_shard($docid);
			$oidx->add_xref3($docid, -1, $smsg->{blob}, '.');
			$idx->shard_add_eidx_info($docid, '.', $eml); # List-Id
			$idx->shard_add_keywords($docid, @kw) if @kw;
		}
	} else {
		$smsg->{num} = $oidx->adj_counter('eidx_docid', '+');
		$oidx->add_overview($eml, $smsg);
		$oidx->add_xref3($smsg->{num}, -1, $smsg->{blob}, '.');
		my $idx = $eidx->idx_shard($smsg->{num});
		$idx->index_raw($msgref, $eml, $smsg);
		$idx->shard_add_keywords($smsg->{num}, @kw) if @kw;
	}
	$smsg->{blob}
}

sub done {
	my ($self) = @_;
	my $err = '';
	if (my $im = delete($self->{im})) {
		eval { $im->done };
		if ($@) {
			$err .= "import done: $@\n";
			warn $err;
		}
	}
	$self->{priv_eidx}->done;
	die $err if $err;
}

1;
