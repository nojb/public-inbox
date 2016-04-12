# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# git fast-import-based ssoma-mda MDA replacement
# This is only ever run by public-inbox-mda and public-inbox-learn,
# not the WWW or NNTP code which only requires read-only access.
package PublicInbox::Import;
use strict;
use warnings;
use Fcntl qw(:flock :DEFAULT);
use Email::Address;
use PublicInbox::Spawn qw(spawn);
use PublicInbox::MID qw(mid_mime mid2path);

sub new {
	my ($class, $git, $name, $email) = @_;
	bless {
		git => $git,
		ident => "$name <$email>",
		mark => 1,
		ref => 'refs/heads/master',
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
	chomp($self->{tip} = $git->qx(qw(rev-parse --revs-only), $self->{ref}));

	my @cmd = ('git', "--git-dir=$git_dir", qw(fast-import
			--quiet --done --date-format=rfc2822));
	my $rdr = { 0 => fileno($out_r), 1 => fileno($in_w) };
	my $pid = spawn(\@cmd, undef, $rdr);
	die "spawn failed: $!" unless defined $pid;
	$out_w->autoflush(1);
	$self->{in} = $in_r;
	$self->{out} = $out_w;
	$self->{lockfh} = $lockfh;
	$self->{pid} = $pid;
	($in_r, $out_w);
}

sub wfail () { die "write to fast-import failed: $!" }

sub now2822 () {
	my @t = gmtime(time);
	my $day = qw(Sun Mon Tue Wed Thu Fri Sat)[$t[6]];
	my $mon = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)[$t[4]];

	sprintf('%s, %2d %s %d %02d:%02d:%02d +0000',
		$day, $t[3], $mon, $t[5] + 1900, $t[2], $t[1], $t[0]);
}

# returns undef on non-existent
# (-1, msg) on mismatch
# (:MARK, msg) on success
sub remove {
	my ($self, $mime) = @_; # mime = Email::MIME

	my $mid = mid_mime($mime);
	my $path = mid2path($mid);

	my ($r, $w) = $self->gfi_start;
	my $tip = $self->{tip};
	return if $tip eq '';

	print $w "ls $tip $path\n" or wfail;
	local $/ = "\n";
	my $check = <$r>;
	defined $check or die "EOF from fast-import / ls: $!";
	return if $check =~ /\Amissing /;
	$check =~ m!\A100644 blob ([a-f0-9]{40})\t!s or die "not blob: $check";
	my $blob = $1;
	print $w "cat-blob $blob\n" or wfail;
	$check = <$r>;
	defined $check or die "EOF from fast-import / cat-blob: $!";
	$check =~ /\A[a-f0-9]{40} blob (\d+)\n\z/ or
				die "unexpected cat-blob response: $check";
	my $left = $1;
	my $offset = 0;
	my $buf = '';
	while ($left > 0) {
		my $n = read($r, $buf, $left, $offset);
		defined($n) or die "read cat-blob failed: $!";
		$n == 0 and die 'fast-export (cat-blob) died';
		$left -= $n;
		$offset += $n;
	}
	read($r, my $lf, 1);
	die "bad read on final byte: <$lf>" if $lf ne "\n";
	my $cur = Email::MIME->new($buf);
	if ($cur->header('Subject') ne $mime->header('Subject') ||
			$cur->body ne $mime->body) {
		return (-1, $cur);
	}

	my $ref = $self->{ref};
	my $commit = $self->{mark}++;
	my $parent = $tip =~ /\A:/ ? $tip : undef;
	unless ($parent) {
		print $w "reset $ref\n" or wfail;
	}
	my $ident = $self->{ident};
	my $now = now2822();
	print $w "commit $ref\nmark :$commit\n",
		"author $ident $now\n",
		"committer $ident $now\n",
		"data 3\nrm\n\n",
		'from ', ($parent ? $parent : $tip), "\n" or wfail;
	print $w "D $path\n\n" or wfail;
	(($self->{tip} = ":$commit"), $cur);
}

# returns undef on duplicate
sub add {
	my ($self, $mime) = @_; # mime = Email::MIME

	my $from = $mime->header('From');
	my @from = Email::Address->parse($from);
	my $name = $from[0]->name;
	my $email = $from[0]->address;
	my $date = $mime->header('Date');
	my $subject = $mime->header('Subject');
	$subject = '(no subject)' unless defined $subject;
	my $mid = mid_mime($mime);
	my $path = mid2path($mid);

	# git gets confused with:
	#  "'A U Thor <u@example.com>' via foo" <foo@example.com>
	# ref:
	# <CAD0k6qSUYANxbjjbE4jTW4EeVwOYgBD=bXkSu=akiYC_CB7Ffw@mail.gmail.com>
	$name =~ s/<([^>]+)>/($1)/g;

	my ($r, $w) = $self->gfi_start;
	my $tip = $self->{tip};
	if ($tip ne '') {
		print $w "ls $tip $path\n" or wfail;
		local $/ = "\n";
		my $check = <$r>;
		defined $check or die "EOF from fast-import: $!";
		return unless $check =~ /\Amissing /;
	}

	# kill potentially confusing/misleading headers
	$mime->header_set($_) for qw(bytes lines content-length status);
	$mime = $mime->as_string;
	my $blob = $self->{mark}++;
	print $w "blob\nmark :$blob\ndata ", length($mime), "\n" or wfail;
	print $w $mime, "\n" or wfail;
	my $ref = $self->{ref};
	my $commit = $self->{mark}++;
	my $parent = $tip =~ /\A:/ ? $tip : undef;

	unless ($parent) {
		print $w "reset $ref\n" or wfail;
	}

	# quiet down wide character warnings:
	binmode $w, ':utf8' or die "binmode :utf8 failed: $!";
	print $w "commit $ref\nmark :$commit\n",
		"author $name <$email> $date\n",
		"committer $self->{ident} ", now2822(), "\n",
		"data ", (bytes::length($subject) + 1), "\n",
		$subject, "\n\n" or wfail;
	binmode $w, ':raw' or die "binmode :raw failed: $!";

	if ($tip ne '') {
		print $w 'from ', ($parent ? $parent : $tip), "\n" or wfail;
	}
	print $w "M 100644 :$blob $path\n\n" or wfail;
	$self->{tip} = ":$commit";
}

sub done {
	my ($self) = @_;
	my $w = delete $self->{out} or return;
	my $r = delete $self->{in} or die 'BUG: missing {in} when done';
	print $w "done\n" or wfail;
	my $pid = delete $self->{pid} or die 'BUG: missing {pid} when done';
	waitpid($pid, 0) == $pid or die 'fast-import did not finish';
	$? == 0 or die "fast-import failed: $?";
	my $lockfh = delete $self->{lockfh} or die "BUG: not locked: $!";
	flock($lockfh, LOCK_UN) or die "unlock failed: $!";
	close $lockfh or die "close lock failed: $!";
}

1;
