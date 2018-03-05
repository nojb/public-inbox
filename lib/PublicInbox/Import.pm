# Copyright (C) 2016-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# git fast-import-based ssoma-mda MDA replacement
# This is only ever run by public-inbox-mda and public-inbox-learn,
# not the WWW or NNTP code which only requires read-only access.
package PublicInbox::Import;
use strict;
use warnings;
use Fcntl qw(:flock :DEFAULT);
use PublicInbox::Spawn qw(spawn);
use PublicInbox::MID qw(mid_mime mid2path);
use PublicInbox::Address;
use Date::Parse qw(str2time);
use Time::Zone qw(tz_offset);

sub new {
	my ($class, $git, $name, $email, $inbox) = @_;
	bless {
		git => $git,
		ident => "$name <$email>",
		mark => 1,
		ref => 'refs/heads/master',
		inbox => $inbox,
	}, $class
}

# idempotent start function
sub gfi_start {
	my ($self) = @_;

	return ($self->{in}, $self->{out}) if $self->{pid};

	my ($in_r, $in_w, $out_r, $out_w);
	pipe($in_r, $in_w) or die "pipe failed: $!";
	pipe($out_r, $out_w) or die "pipe failed: $!";
	my $git = $self->{git};
	my $git_dir = $git->{git_dir};
	my $lockpath = "$git_dir/ssoma.lock";
	sysopen(my $lockfh, $lockpath, O_WRONLY|O_CREAT) or
		die "failed to open lock $lockpath: $!";

	# wait for other processes to be done
	flock($lockfh, LOCK_EX) or die "lock failed: $!\n";
	local $/ = "\n";
	chomp($self->{tip} = $git->qx(qw(rev-parse --revs-only), $self->{ref}));

	my @cmd = ('git', "--git-dir=$git_dir", qw(fast-import
			--quiet --done --date-format=raw));
	my $rdr = { 0 => fileno($out_r), 1 => fileno($in_w) };
	my $pid = spawn(\@cmd, undef, $rdr);
	die "spawn fast-import failed: $!" unless defined $pid;
	$out_w->autoflush(1);
	$self->{in} = $in_r;
	$self->{out} = $out_w;
	$self->{lockfh} = $lockfh;
	$self->{pid} = $pid;
	$self->{nchg} = 0;
	binmode $out_w, ':raw' or die "binmode :raw failed: $!";
	binmode $in_r, ':raw' or die "binmode :raw failed: $!";
	($in_r, $out_w);
}

sub wfail () { die "write to fast-import failed: $!" }

sub now_raw () { time . ' +0000' }

sub norm_body ($) {
	my ($mime) = @_;
	my $b = $mime->body_raw;
	$b =~ s/(\r?\n)+\z//s;
	$b
}

sub _check_path ($$$$) {
	my ($r, $w, $tip, $path) = @_;
	return if $tip eq '';
	print $w "ls $tip $path\n" or wfail;
	local $/ = "\n";
	defined(my $info = <$r>) or die "EOF from fast-import: $!";
	$info =~ /\Amissing / ? undef : $info;
}

# returns undef on non-existent
# ('MISMATCH', msg) on mismatch
# (:MARK, msg) on success
sub remove {
	my ($self, $mime, $msg) = @_; # mime = Email::MIME

	my $mid = mid_mime($mime);
	my $path = mid2path($mid);

	my ($r, $w) = $self->gfi_start;
	my $tip = $self->{tip};
	my $info = _check_path($r, $w, $tip, $path) or return ('MISSING',undef);
	$info =~ m!\A100644 blob ([a-f0-9]{40})\t!s or die "not blob: $info";
	my $blob = $1;

	print $w "cat-blob $blob\n" or wfail;
	local $/ = "\n";
	$info = <$r>;
	defined $info or die "EOF from fast-import / cat-blob: $!";
	$info =~ /\A[a-f0-9]{40} blob (\d+)\n\z/ or
				die "unexpected cat-blob response: $info";
	my $left = $1;
	my $offset = 0;
	my $buf = '';
	my $n;
	while ($left > 0) {
		$n = read($r, $buf, $left, $offset);
		defined($n) or die "read cat-blob failed: $!";
		$n == 0 and die 'fast-export (cat-blob) died';
		$left -= $n;
		$offset += $n;
	}
	$n = read($r, my $lf, 1);
	defined($n) or die "read final byte of cat-blob failed: $!";
	die "bad read on final byte: <$lf>" if $lf ne "\n";
	my $cur = PublicInbox::MIME->new($buf);
	my $cur_s = $cur->header('Subject');
	$cur_s = '' unless defined $cur_s;
	my $cur_m = $mime->header('Subject');
	$cur_m = '' unless defined $cur_m;
	if ($cur_s ne $cur_m || norm_body($cur) ne norm_body($mime)) {
		return ('MISMATCH', $cur);
	}

	my $ref = $self->{ref};
	my $commit = $self->{mark}++;
	my $parent = $tip =~ /\A:/ ? $tip : undef;
	unless ($parent) {
		print $w "reset $ref\n" or wfail;
	}
	my $ident = $self->{ident};
	my $now = now_raw();
	$msg ||= 'rm';
	my $len = length($msg) + 1;
	print $w "commit $ref\nmark :$commit\n",
		"author $ident $now\n",
		"committer $ident $now\n",
		"data $len\n$msg\n\n",
		'from ', ($parent ? $parent : $tip), "\n" or wfail;
	print $w "D $path\n\n" or wfail;
	$self->{nchg}++;
	(($self->{tip} = ":$commit"), $cur);
}

sub parse_date ($) {
	my ($mime) = @_;
	my $hdr = $mime->header_obj;
	my $date = $hdr->header_raw('Date');
	my ($ts, $zone);
	my $mid = $hdr->header_raw('Message-ID');
	if ($date) {
		$ts = eval { str2time($date) };
		if ($@) {
			warn "bad Date: $date in $mid: $@\n";
		} elsif ($date =~ /\s+([\+\-]\d+)\s*\z/) {
			$zone = $1;
		}
	}
	unless ($ts) {
		my @recvd = $hdr->header_raw('Received');
		foreach my $r (@recvd) {
			$zone = undef;
			$r =~ /\s*(\d+\s+[[:alpha:]]+\s+\d{2,4}\s+
				\d+\D\d+(?:\D\d+)\s+([\+\-]\d+))/osx or next;
			$zone = $2;
			$ts = eval { str2time($1) } and last;
			warn "no date in Received: $r\n";
		}
	}
	$zone ||= '+0000';
	# "-1200" is the furthest westermost zone offset,
	# but git fast-import is liberal so we use "-1400"
	if ($zone >= 1400 || $zone <= -1400) {
		warn "bogus TZ offset: $zone, ignoring and assuming +0000\n";
		$zone = '+0000';
	}
	$ts ||= time;
	$ts = 0 if $ts < 0; # git uses unsigned times
	"$ts $zone";
}

# returns undef on duplicate
sub add {
	my ($self, $mime, $check_cb) = @_; # mime = Email::MIME

	my $from = $mime->header('From');
	my ($email) = PublicInbox::Address::emails($from);
	my ($name) = PublicInbox::Address::names($from);
	# git gets confused with:
	#  "'A U Thor <u@example.com>' via foo" <foo@example.com>
	# ref:
	# <CAD0k6qSUYANxbjjbE4jTW4EeVwOYgBD=bXkSu=akiYC_CB7Ffw@mail.gmail.com>
	$name =~ tr/<>//d;

	my $date_raw = parse_date($mime);
	my $subject = $mime->header('Subject');
	$subject = '(no subject)' unless defined $subject;
	my $mid = mid_mime($mime);
	my $path = mid2path($mid);

	my ($r, $w) = $self->gfi_start;
	my $tip = $self->{tip};
	_check_path($r, $w, $tip, $path) and return;

	# kill potentially confusing/misleading headers
	$mime->header_set($_) for qw(bytes lines content-length status);
	if ($check_cb) {
		$mime = $check_cb->($mime) or return;
	}

	my $blob = $self->{mark}++;
	my $str = $mime->as_string;
	print $w "blob\nmark :$blob\ndata ", length($str), "\n" or wfail;
	print $w $str, "\n" or wfail;
	$str = undef;
	my $ref = $self->{ref};
	my $commit = $self->{mark}++;
	my $parent = $tip =~ /\A:/ ? $tip : undef;

	unless ($parent) {
		print $w "reset $ref\n" or wfail;
	}

	utf8::encode($email);
	utf8::encode($name);
	utf8::encode($subject);
	# quiet down wide character warnings:
	print $w "commit $ref\nmark :$commit\n",
		"author $name <$email> $date_raw\n",
		"committer $self->{ident} ", now_raw(), "\n" or wfail;
	print $w "data ", (length($subject) + 1), "\n",
		$subject, "\n\n" or wfail;
	if ($tip ne '') {
		print $w 'from ', ($parent ? $parent : $tip), "\n" or wfail;
	}
	print $w "M 100644 :$blob $path\n\n" or wfail;
	$self->{nchg}++;
	$self->{tip} = ":$commit";
}

sub run_die ($$) {
	my ($cmd, $env) = @_;
	my $pid = spawn($cmd, $env, undef);
	defined $pid or die "spawning ".join(' ', @$cmd)." failed: $!";
	waitpid($pid, 0) == $pid or die join(' ', @$cmd) .' did not finish';
	$? == 0 or die join(' ', @$cmd) . " failed: $?\n";
}

sub done {
	my ($self) = @_;
	my $w = delete $self->{out} or return;
	my $r = delete $self->{in} or die 'BUG: missing {in} when done';
	print $w "done\n" or wfail;
	my $pid = delete $self->{pid} or die 'BUG: missing {pid} when done';
	waitpid($pid, 0) == $pid or die 'fast-import did not finish';
	$? == 0 or die "fast-import failed: $?";
	my $nchg = delete $self->{nchg};

	# for compatibility with existing ssoma installations
	# we can probably remove this entirely by 2020
	my $git_dir = $self->{git}->{git_dir};
	# XXX: change the following scope to: if (-e $index) # in 2018 or so..
	my @cmd = ('git', "--git-dir=$git_dir");
	if ($nchg && !$ENV{FAST}) {
		my $index = "$git_dir/ssoma.index";
		my $env = { GIT_INDEX_FILE => $index };
		run_die([@cmd, qw(read-tree -m -v -i), $self->{ref}], $env);
	}
	if ($nchg) {
		run_die([@cmd, 'update-server-info'], undef);
		eval {
			require PublicInbox::SearchIdx;
			my $inbox = $self->{inbox} || $git_dir;
			my $s = PublicInbox::SearchIdx->new($inbox);
			$s->index_sync({ ref => $self->{ref} });
		};

		eval { run_die([@cmd, qw(gc --auto)], undef) };
	}

	my $lockfh = delete $self->{lockfh} or die "BUG: not locked: $!";
	flock($lockfh, LOCK_UN) or die "unlock failed: $!";
	close $lockfh or die "close lock failed: $!";
}

1;
__END__
=pod

=head1 NAME

PublicInbox::Import - message importer for public-inbox

=head1 VERSION

version 1.0

=head1 SYNOPSYS

	use Email::MIME;
	use PublicInbox::Git;
	use PublicInbox::Import;

	chomp(my $git_dir = `git rev-parse --git-dir`);
	$git_dir or die "GIT_DIR= must be specified\n";
	my $git = PublicInbox::Git->new($git_dir);
	my @committer = ('inbox', 'inbox@example.org');
	my $im = PublicInbox::Import->new($git, @committer);

	# to add a message:
	my $message = "From: <u\@example.org>\n".
		"Subject: test message \n" .
		"Date: Thu, 01 Jan 1970 00:00:00 +0000\n" .
		"Message-ID: <m\@example.org>\n".
		"\ntest message";
	my $parsed = Email::MIME->new($message);
	my $ret = $im->add($parsed);
	if (!defined $ret) {
		warn "duplicate: ",
			$parsed->header_obj->header_raw('Message-ID'), "\n";
	} else {
		print "imported at mark $ret\n";
	}
	$im->done;

	# to remove a message
	my $junk = Email::MIME->new($message);
	my ($mark, $orig) = $im->remove($junk);
	if ($mark eq 'MISSING') {
		print "not found\n";
	} elsif ($mark eq 'MISMATCH') {
		print "Message exists but does not match\n\n",
			$orig->as_string, "\n",;
	} else {
		print "removed at mark $mark\n\n",
			$orig->as_string, "\n";
	}
	$im->done;

=head1 DESCRIPTION

An importer and remover for public-inboxes which takes L<Email::MIME>
messages as input and stores them in a ssoma repository as
documented in L<https://ssoma.public-inbox.org/ssoma_repository.txt>,
except it does not allow duplicate Message-IDs.

It requires L<git(1)> and L<git-fast-import(1)> to be installed.

=head1 METHODS

=cut

=head2 new

	my $im = PublicInbox::Import->new($git, @committer);

Initialize a new PublicInbox::Import object.

=head2 add

	my $parsed = Email::MIME->new($message);
	$im->add($parsed);

Adds a message to to the git repository.  This will acquire
C<$GIT_DIR/ssoma.lock> and start L<git-fast-import(1)> if necessary.

Messages added will not be visible to other processes until L</done>
is called, but L</remove> may be called on them.

=head2 remove

	my $junk = Email::MIME->new($message);
	my ($code, $orig) = $im->remove($junk);

Removes a message from the repository.  On success, it returns
a ':'-prefixed numeric code representing the git-fast-import
mark and the original messages as an Email::MIME object.
If the message could not be found, the code is "MISSING"
and the original message is undef.  If there is a mismatch where
the "Message-ID" is matched but the subject and body do not match,
the returned code is "MISMATCH" and the conflicting message
is returned as orig.

=head2 done

Finalizes the L<git-fast-import(1)> and unlocks the repository.
Calling this is required to finalize changes to a repository.

=head1 SEE ALSO

L<Email::MIME>

=head1 CONTACT

All feedback welcome via plain-text mail to L<mailto:meta@public-inbox.org>

The mail archives are hosted at L<https://public-inbox.org/meta/>

=head1 COPYRIGHT

Copyright (C) 2016 all contributors L<mailto:meta@public-inbox.org>

License: AGPL-3.0+ L<http://www.gnu.org/licenses/agpl-3.0.txt>

=cut
