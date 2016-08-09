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
	local $/ = "\n";
	chomp($self->{tip} = $git->qx(qw(rev-parse --revs-only), $self->{ref}));

	my @cmd = ('git', "--git-dir=$git_dir", qw(fast-import
			--quiet --done --date-format=rfc2822));
	my $rdr = { 0 => fileno($out_r), 1 => fileno($in_w) };
	my $pid = spawn(\@cmd, undef, $rdr);
	die "spawn fast-import failed: $!" unless defined $pid;
	$out_w->autoflush(1);
	$self->{in} = $in_r;
	$self->{out} = $out_w;
	$self->{lockfh} = $lockfh;
	$self->{pid} = $pid;
	$self->{nchg} = 0;
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

sub norm_body ($) {
	my ($mime) = @_;
	my $b = $mime->body_raw;
	$b =~ s/(\r?\n)+\z//s;
	$b
}

# returns undef on non-existent
# ('MISMATCH', msg) on mismatch
# (:MARK, msg) on success
sub remove {
	my ($self, $mime) = @_; # mime = Email::MIME

	my $mid = mid_mime($mime);
	my $path = mid2path($mid);

	my ($r, $w) = $self->gfi_start;
	my $tip = $self->{tip};
	return ('MISSING', undef) if $tip eq '';

	print $w "ls $tip $path\n" or wfail;
	local $/ = "\n";
	my $check = <$r>;
	defined $check or die "EOF from fast-import / ls: $!";
	return ('MISSING', undef) if $check =~ /\Amissing /;
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
	my $cur = Email::MIME->new($buf);
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
	my $now = now2822();
	print $w "commit $ref\nmark :$commit\n",
		"author $ident $now\n",
		"committer $ident $now\n",
		"data 3\nrm\n\n",
		'from ', ($parent ? $parent : $tip), "\n" or wfail;
	print $w "D $path\n\n" or wfail;
	$self->{nchg}++;
	(($self->{tip} = ":$commit"), $cur);
}

# returns undef on duplicate
sub add {
	my ($self, $mime, $check_cb) = @_; # mime = Email::MIME

	my $from = $mime->header('From');
	my ($email) = ($from =~ /([^<\s]+\@[^>\s]+)/g);
	my $name = $from;
	$name =~ s/\s*\S+\@\S+\s*\z//;
	# git gets confused with:
	#  "'A U Thor <u@example.com>' via foo" <foo@example.com>
	# ref:
	# <CAD0k6qSUYANxbjjbE4jTW4EeVwOYgBD=bXkSu=akiYC_CB7Ffw@mail.gmail.com>
	$name =~ tr/<>// and $name = $email;

	my $date = $mime->header('Date');
	my $subject = $mime->header('Subject');
	$subject = '(no subject)' unless defined $subject;
	my $mid = mid_mime($mime);
	my $path = mid2path($mid);

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
	if ($check_cb) {
		$mime = $check_cb->($mime) or return;
	}

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
	$self->{nchg}++;
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
	my $nchg = delete $self->{nchg};

	# for compatibility with existing ssoma installations
	# we can probably remove this entirely by 2020
	my $git_dir = $self->{git}->{git_dir};
	# XXX: change the following scope to: if (-e $index) # in 2018 or so..
	my @cmd = ('git', "--git-dir=$git_dir");
	if ($nchg && !$ENV{FAST}) {
		my $index = "$git_dir/ssoma.index";
		my $env = { GIT_INDEX_FILE => $index };
		my @rt = (@cmd, qw(read-tree -m -v -i), $self->{ref});
		$pid = spawn(\@rt, $env, undef);
		defined $pid or die "spawn read-tree failed: $!";
		waitpid($pid, 0) == $pid or die 'read-tree did not finish';
		$? == 0 or die "failed to update $git_dir/ssoma.index: $?\n";
	}
	if ($nchg) {
		$pid = spawn([@cmd, 'update-server-info'], undef, undef);
		defined $pid or die "spawn update-server-info failed: $!\n";
		waitpid($pid, 0) == $pid or
			die 'update-server-info did not finish';
		$? == 0 or die "failed to update-server-info: $?\n";

		eval {
			require PublicInbox::SearchIdx;
			my $s = PublicInbox::SearchIdx->new($git_dir);
			$s->index_sync({ ref => $self->{ref} });
		};
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
