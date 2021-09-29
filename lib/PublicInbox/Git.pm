# Copyright (C) 2014-2021 all contributors <meta@public-inbox.org>
# License: GPLv2 or later <https://www.gnu.org/licenses/gpl-2.0.txt>
#
# Used to read files from a git repository without excessive forking.
# Used in our web interfaces as well as our -nntpd server.
# This is based on code in Git.pm which is GPLv2+, but modified to avoid
# dependence on environment variables for compatibility with mod_perl.
# There are also API changes to simplify our usage and data set.
package PublicInbox::Git;
use strict;
use v5.10.1;
use parent qw(Exporter);
use POSIX ();
use IO::Handle; # ->autoflush
use Errno qw(EINTR EAGAIN ENOENT);
use File::Glob qw(bsd_glob GLOB_NOSORT);
use File::Spec ();
use Time::HiRes qw(stat);
use PublicInbox::Spawn qw(popen_rd spawn);
use PublicInbox::Tmpfile;
use IO::Poll qw(POLLIN);
use Carp qw(croak);
use Digest::SHA ();
use PublicInbox::DS qw(dwaitpid);
our @EXPORT_OK = qw(git_unquote git_quote);
our $PIPE_BUFSIZ = 65536; # Linux default
our $in_cleanup;
our $RDTIMEO = 60_000; # milliseconds

use constant MAX_INFLIGHT => (POSIX::PIPE_BUF * 3) /
	65; # SHA-256 hex size + "\n" in preparation for git using non-SHA1

my %GIT_ESC = (
	a => "\a",
	b => "\b",
	f => "\f",
	n => "\n",
	r => "\r",
	t => "\t",
	v => "\013",
	'"' => '"',
	'\\' => '\\',
);
my %ESC_GIT = map { $GIT_ESC{$_} => $_ } keys %GIT_ESC;


# unquote pathnames used by git, see quote.c::unquote_c_style.c in git.git
sub git_unquote ($) {
	return $_[0] unless ($_[0] =~ /\A"(.*)"\z/);
	$_[0] = $1;
	$_[0] =~ s!\\([\\"abfnrtv]|[0-3][0-7]{2})!$GIT_ESC{$1}//chr(oct($1))!ge;
	$_[0];
}

sub git_quote ($) {
	if ($_[0] =~ s/([\\"\a\b\f\n\r\t\013]|[^[:print:]])/
		      '\\'.($ESC_GIT{$1}||sprintf("%03o",ord($1)))/egs) {
		return qq{"$_[0]"};
	}
	$_[0];
}

sub new {
	my ($class, $git_dir) = @_;
	$git_dir =~ tr!/!/!s;
	$git_dir =~ s!/*\z!!s;
	# may contain {-tmp} field for File::Temp::Dir
	bless { git_dir => $git_dir, alt_st => '', -git_path => {} }, $class
}

sub git_path ($$) {
	my ($self, $path) = @_;
	$self->{-git_path}->{$path} ||= do {
		local $/ = "\n";
		chomp(my $str = $self->qx(qw(rev-parse --git-path), $path));

		# git prior to 2.5.0 did not understand --git-path
		if ($str eq "--git-path\n$path") {
			$str = "$self->{git_dir}/$path";
		}
		$str;
	};
}

sub alternates_changed {
	my ($self) = @_;
	my $alt = git_path($self, 'objects/info/alternates');
	my @st = stat($alt) or return 0;

	# can't rely on 'q' on some 32-bit builds, but `d' works
	my $st = pack('dd', $st[10], $st[7]); # 10: ctime, 7: size
	return 0 if $self->{alt_st} eq $st;
	$self->{alt_st} = $st; # always a true value
}

sub last_check_err {
	my ($self) = @_;
	my $fh = $self->{err_c} or return;
	sysseek($fh, 0, 0) or $self->fail("sysseek failed: $!");
	defined(sysread($fh, my $buf, -s $fh)) or
			$self->fail("sysread failed: $!");
	$buf;
}

sub _bidi_pipe {
	my ($self, $batch, $in, $out, $pid, $err) = @_;
	if ($self->{$pid}) {
		if (defined $err) { # "err_c"
			my $fh = $self->{$err};
			sysseek($fh, 0, 0) or $self->fail("sysseek failed: $!");
			truncate($fh, 0) or $self->fail("truncate failed: $!");
		}
		return;
	}
	pipe(my ($out_r, $out_w)) or $self->fail("pipe failed: $!");
	my $rdr = { 0 => $out_r };
	my $gd = $self->{git_dir};
	if ($gd =~ s!/([^/]+/[^/]+)\z!/!) {
		$rdr->{-C} = $gd;
		$gd = $1;
	}
	my @cmd = (qw(git), "--git-dir=$gd",
			qw(-c core.abbrev=40 cat-file), $batch);
	if ($err) {
		my $id = "git.$self->{git_dir}$batch.err";
		my $fh = tmpfile($id) or $self->fail("tmpfile($id): $!");
		$self->{$err} = $fh;
		$rdr->{2} = $fh;
	}
	my ($in_r, $p) = popen_rd(\@cmd, undef, $rdr);
	$self->{$pid} = $p;
	$self->{"$pid.owner"} = $$;
	$out_w->autoflush(1);
	if ($^O eq 'linux') { # 1031: F_SETPIPE_SZ
		fcntl($out_w, 1031, 4096);
		fcntl($in_r, 1031, 4096) if $batch eq '--batch-check';
	}
	$self->{$out} = $out_w;
	$self->{$in} = $in_r;
}

sub poll_in ($) { IO::Poll::_poll($RDTIMEO, fileno($_[0]), my $ev = POLLIN) }

sub my_read ($$$) {
	my ($fh, $rbuf, $len) = @_;
	my $left = $len - length($$rbuf);
	my $r;
	while ($left > 0) {
		$r = sysread($fh, $$rbuf, $PIPE_BUFSIZ, length($$rbuf));
		if ($r) {
			$left -= $r;
		} elsif (defined($r)) { # EOF
			return 0;
		} else {
			next if ($! == EAGAIN and poll_in($fh));
			next if $! == EINTR; # may be set by sysread or poll_in
			return; # unrecoverable error
		}
	}
	\substr($$rbuf, 0, $len, '');
}

sub my_readline ($$) {
	my ($fh, $rbuf) = @_;
	while (1) {
		if ((my $n = index($$rbuf, "\n")) >= 0) {
			return substr($$rbuf, 0, $n + 1, '');
		}
		my $r = sysread($fh, $$rbuf, $PIPE_BUFSIZ, length($$rbuf))
								and next;

		# return whatever's left on EOF
		return substr($$rbuf, 0, length($$rbuf)+1, '') if defined($r);

		next if ($! == EAGAIN and poll_in($fh));
		next if $! == EINTR; # may be set by sysread or poll_in
		return; # unrecoverable error
	}
}

sub cat_async_retry ($$$$$) {
	my ($self, $inflight, $req, $cb, $arg) = @_;

	# {inflight} may be non-existent, but if it isn't we delete it
	# here to prevent cleanup() from waiting:
	delete $self->{inflight};
	cleanup($self);

	$self->{inflight} = $inflight;
	batch_prepare($self);
	my $buf = "$req\n";
	for (my $i = 0; $i < @$inflight; $i += 3) {
		$buf .= "$inflight->[$i]\n";
	}
	print { $self->{out} } $buf or $self->fail("write error: $!");
	unshift(@$inflight, \$req, $cb, $arg); # \$ref to indicate retried

	cat_async_step($self, $inflight); # take one step
}

sub cat_async_step ($$) {
	my ($self, $inflight) = @_;
	die 'BUG: inflight empty or odd' if scalar(@$inflight) < 3;
	my ($req, $cb, $arg) = splice(@$inflight, 0, 3);
	my $rbuf = delete($self->{cat_rbuf}) // \(my $new = '');
	my ($bref, $oid, $type, $size);
	my $head = my_readline($self->{in}, $rbuf);
	# ->fail may be called via Gcf2Client.pm
	if ($head =~ /^([0-9a-f]{40,}) (\S+) ([0-9]+)$/) {
		($oid, $type, $size) = ($1, $2, $3 + 0);
		$bref = my_read($self->{in}, $rbuf, $size + 1) or
			$self->fail(defined($bref) ? 'read EOF' : "read: $!");
		chop($$bref) eq "\n" or $self->fail('LF missing after blob');
	} elsif ($head =~ s/ missing\n//s) {
		$oid = $head;
		# ref($req) indicates it's already been retried
		# -gcf2 retries internally, so it never hits this path:
		if (!ref($req) && !$in_cleanup && $self->alternates_changed) {
			return cat_async_retry($self, $inflight,
						$req, $cb, $arg);
		}
		$type = 'missing';
		$oid = ref($req) ? $$req : $req if $oid eq '';
	} else {
		my $err = $! ? " ($!)" : '';
		$self->fail("bad result from async cat-file: $head$err");
	}
	$self->{cat_rbuf} = $rbuf if $$rbuf ne '';
	eval { $cb->($bref, $oid, $type, $size, $arg) };
	warn "E: $oid: $@\n" if $@;
}

sub cat_async_wait ($) {
	my ($self) = @_;
	my $inflight = $self->{inflight} or return;
	while (scalar(@$inflight)) {
		cat_async_step($self, $inflight);
	}
}

sub batch_prepare ($) {
	_bidi_pipe($_[0], qw(--batch in out pid));
}

sub _cat_file_cb {
	my ($bref, $oid, $type, $size, $result) = @_;
	@$result = ($bref, $oid, $type, $size);
}

sub cat_file {
	my ($self, $oid) = @_;
	my $result = [];
	cat_async($self, $oid, \&_cat_file_cb, $result);
	cat_async_wait($self);
	wantarray ? @$result : $result->[0];
}

sub check_async_step ($$) {
	my ($self, $inflight_c) = @_;
	die 'BUG: inflight empty or odd' if scalar(@$inflight_c) < 3;
	my ($req, $cb, $arg) = splice(@$inflight_c, 0, 3);
	my $rbuf = delete($self->{chk_rbuf}) // \(my $new = '');
	chomp(my $line = my_readline($self->{in_c}, $rbuf));
	my ($hex, $type, $size) = split(/ /, $line);

	# Future versions of git.git may have type=ambiguous, but for now,
	# we must handle 'dangling' below (and maybe some other oddball
	# stuff):
	# https://public-inbox.org/git/20190118033845.s2vlrb3wd3m2jfzu@dcvr/T/
	if ($hex eq 'dangling' || $hex eq 'notdir' || $hex eq 'loop') {
		my $ret = my_read($self->{in_c}, $rbuf, $type + 1);
		$self->fail(defined($ret) ? 'read EOF' : "read: $!") if !$ret;
	}
	$self->{chk_rbuf} = $rbuf if $$rbuf ne '';
	eval { $cb->($hex, $type, $size, $arg, $self) };
	warn "E: check($req) $@\n" if $@;
}

sub check_async_wait ($) {
	my ($self) = @_;
	my $inflight_c = $self->{inflight_c} or return;
	while (scalar(@$inflight_c)) {
		check_async_step($self, $inflight_c);
	}
}

sub check_async_begin ($) {
	my ($self) = @_;
	cleanup($self) if alternates_changed($self);
	_bidi_pipe($self, qw(--batch-check in_c out_c pid_c err_c));
	die 'BUG: already in async check' if $self->{inflight_c};
	$self->{inflight_c} = [];
}

sub check_async ($$$$) {
	my ($self, $oid, $cb, $arg) = @_;
	my $inflight_c = $self->{inflight_c} // check_async_begin($self);
	while (scalar(@$inflight_c) >= MAX_INFLIGHT) {
		check_async_step($self, $inflight_c);
	}
	print { $self->{out_c} } $oid, "\n" or $self->fail("write error: $!");
	push(@$inflight_c, $oid, $cb, $arg);
}

sub _check_cb { # check_async callback
	my ($hex, $type, $size, $result) = @_;
	@$result = ($hex, $type, $size);
}

sub check {
	my ($self, $oid) = @_;
	my $result = [];
	check_async($self, $oid, \&_check_cb, $result);
	check_async_wait($self);
	my ($hex, $type, $size) = @$result;

	# Future versions of git.git may show 'ambiguous', but for now,
	# we must handle 'dangling' below (and maybe some other oddball
	# stuff):
	# https://public-inbox.org/git/20190118033845.s2vlrb3wd3m2jfzu@dcvr/T/
	return if $type eq 'missing' || $type eq 'ambiguous';
	return if $hex eq 'dangling' || $hex eq 'notdir' || $hex eq 'loop';
	($hex, $type, $size);
}

sub _destroy {
	my ($self, $rbuf, $in, $out, $pid, $err) = @_;
	delete @$self{($rbuf, $in, $out)};
	delete $self->{$err} if $err; # `err_c'

	# GitAsyncCat::event_step may delete {pid}
	my $p = delete $self->{$pid} or return;
	dwaitpid($p) if $$ == $self->{"$pid.owner"};
}

sub cat_async_abort ($) {
	my ($self) = @_;
	if (my $inflight = $self->{inflight}) {
		while (@$inflight) {
			my ($req, $cb, $arg) = splice(@$inflight, 0, 3);
			$req =~ s/ .*//; # drop git_dir for Gcf2Client
			eval { $cb->(undef, $req, undef, undef, $arg) };
			warn "E: $req: $@ (in abort)\n" if $@;
		}
		delete $self->{cat_rbuf};
		delete $self->{inflight};
	}
	cleanup($self);
}

sub fail { # may be augmented in subclasses
	my ($self, $msg) = @_;
	cat_async_abort($self);
	croak(ref($self) . ' ' . ($self->{git_dir} // '') . ": $msg");
}

# $git->popen(qw(show f00)); # or
# $git->popen(qw(show f00), { GIT_CONFIG => ... }, { 2 => ... });
sub popen {
	my ($self, $cmd) = splice(@_, 0, 2);
	$cmd = [ 'git', "--git-dir=$self->{git_dir}",
		ref($cmd) ? @$cmd : ($cmd, grep { defined && !ref } @_) ];
	popen_rd($cmd, grep { !defined || ref } @_); # env and opt
}

# same args as popen above
sub qx {
	my $fh = popen(@_);
	if (wantarray) {
		my @ret = <$fh>;
		close $fh; # caller should check $?
		@ret;
	} else {
		local $/;
		my $ret = <$fh>;
		close $fh; # caller should check $?
		$ret;
	}
}

sub date_parse {
	my $self = shift;
	map {
		substr($_, length('--max-age='), -1)
	} $self->qx('rev-parse', map { "--since=$_" } @_);
}

# check_async and cat_async may trigger the other, so ensure they're
# both completely done by using this:
sub async_wait_all ($) {
	my ($self) = @_;
	while (scalar(@{$self->{inflight_c} // []}) ||
			scalar(@{$self->{inflight} // []})) {
		$self->check_async_wait;
		$self->cat_async_wait;
	}
}

# returns true if there are pending "git cat-file" processes
sub cleanup {
	my ($self, $lazy) = @_;
	local $in_cleanup = 1;
	return 1 if $lazy && (scalar(@{$self->{inflight_c} // []}) ||
				scalar(@{$self->{inflight} // []}));
	delete $self->{async_cat};
	async_wait_all($self);
	delete $self->{inflight};
	delete $self->{inflight_c};
	_destroy($self, qw(cat_rbuf in out pid));
	_destroy($self, qw(chk_rbuf in_c out_c pid_c err_c));
	defined($self->{pid}) || defined($self->{pid_c});
}

# assuming a well-maintained repo, this should be a somewhat
# accurate estimation of its size
# TODO: show this in the WWW UI as a hint to potential cloners
sub packed_bytes {
	my ($self) = @_;
	my $n = 0;
	my $pack_dir = git_path($self, 'objects/pack');
	foreach my $p (bsd_glob("$pack_dir/*.pack", GLOB_NOSORT)) {
		$n += -s $p;
	}
	$n
}

sub DESTROY { cleanup(@_) }

sub local_nick ($) {
	my ($self) = @_;
	my $ret = '???';
	# don't show full FS path, basename should be OK:
	if ($self->{git_dir} =~ m!/([^/]+)(?:/*\.git/*)?\z!) {
		$ret = "$1.git";
	}
	wantarray ? ($ret) : $ret;
}

sub host_prefix_url ($$) {
	my ($env, $url) = @_;
	return $url if index($url, '//') >= 0;
	my $scheme = $env->{'psgi.url_scheme'};
	my $host_port = $env->{HTTP_HOST} //
		"$env->{SERVER_NAME}:$env->{SERVER_PORT}";
	"$scheme://$host_port". ($env->{SCRIPT_NAME} || '/') . $url;
}

sub pub_urls {
	my ($self, $env) = @_;
	if (my $urls = $self->{cgit_url}) {
		return map { host_prefix_url($env, $_) } @$urls;
	}
	local_nick($self);
}

sub cat_async_begin {
	my ($self) = @_;
	cleanup($self) if $self->alternates_changed;
	$self->batch_prepare;
	die 'BUG: already in async' if $self->{inflight};
	$self->{inflight} = [];
}

sub cat_async ($$$;$) {
	my ($self, $oid, $cb, $arg) = @_;
	my $inflight = $self->{inflight} // cat_async_begin($self);
	while (scalar(@$inflight) >= MAX_INFLIGHT) {
		cat_async_step($self, $inflight);
	}
	print { $self->{out} } $oid, "\n" or $self->fail("write error: $!");
	push(@$inflight, $oid, $cb, $arg);
}

# returns the modified time of a git repo, same as the "modified" field
# of a grokmirror manifest
sub modified ($) {
	# committerdate:unix is git 2.9.4+ (2017-05-05), so using raw instead
	my $fh = popen($_[0], qw[for-each-ref --sort=-committerdate
				--format=%(committerdate:raw) --count=1]);
	(split(/ /, <$fh> // time))[0] + 0; # integerize for JSON
}

# for grokmirror, which doesn't read gitweb.description
# templates/hooks--update.sample and git-multimail in git.git
# only match "Unnamed repository", not the full contents of
# templates/this--description in git.git
sub manifest_entry {
	my ($self, $epoch, $default_desc) = @_;
	my $fh = $self->popen('show-ref');
	my $dig = Digest::SHA->new(1);
	while (read($fh, my $buf, 65536)) {
		$dig->add($buf);
	}
	close $fh or return; # empty, uninitialized git repo
	undef $fh; # for open, below
	my $git_dir = $self->{git_dir};
	my $ent = {
		fingerprint => $dig->hexdigest,
		reference => undef,
		modified => modified($self),
	};
	chomp(my $owner = $self->qx('config', 'gitweb.owner'));
	utf8::decode($owner);
	$ent->{owner} = $owner eq '' ? undef : $owner;
	my $desc = '';
	if (open($fh, '<', "$git_dir/description")) {
		local $/ = "\n";
		chomp($desc = <$fh>);
		utf8::decode($desc);
	}
	$desc = 'Unnamed repository' if $desc eq '';
	if (defined $epoch && $desc =~ /\AUnnamed repository/) {
		$desc = "$default_desc [epoch $epoch]";
	}
	$ent->{description} = $desc;
	if (open($fh, '<', "$git_dir/objects/info/alternates")) {
		# n.b.: GitPython doesn't seem to handle comments or C-quoted
		# strings like native git does; and we don't for now, either.
		local $/ = "\n";
		chomp(my @alt = <$fh>);

		# grokmirror only supports 1 alternate for "reference",
		if (scalar(@alt) == 1) {
			my $objdir = "$git_dir/objects";
			my $ref = File::Spec->rel2abs($alt[0], $objdir);
			$ref =~ s!/[^/]+/?\z!!; # basename
			$ent->{reference} = $ref;
		}
	}
	$ent;
}

# returns true if there are pending cat-file processes
sub cleanup_if_unlinked {
	my ($self) = @_;
	return cleanup($self, 1) if $^O ne 'linux';
	# Linux-specific /proc/$PID/maps access
	# TODO: support this inside git.git
	my $ret = 0;
	for my $fld (qw(pid pid_c)) {
		my $pid = $self->{$fld} // next;
		open my $fh, '<', "/proc/$pid/maps" or return cleanup($self, 1);
		while (<$fh>) {
			# n.b. we do not restart for unlinked multi-pack-index
			# since it's not too huge, and the startup cost may
			# be higher.
			/\.(?:idx|pack) \(deleted\)$/ and
				return cleanup($self, 1);
		}
		++$ret;
	}
	$ret;
}

1;
__END__
=pod

=head1 NAME

PublicInbox::Git - git wrapper

=head1 VERSION

version 1.0

=head1 SYNOPSIS

	use PublicInbox::Git;
	chomp(my $git_dir = `git rev-parse --git-dir`);
	$git_dir or die "GIT_DIR= must be specified\n";
	my $git = PublicInbox::Git->new($git_dir);

=head1 DESCRIPTION

Unstable API outside of the L</new> method.
It requires L<git(1)> to be installed.

=head1 METHODS

=cut

=head2 new

	my $git = PublicInbox::Git->new($git_dir);

Initialize a new PublicInbox::Git object for use with L<PublicInbox::Import>
This is the only public API method we support.  Everything else
in this module is subject to change.

=head1 SEE ALSO

L<Git>, L<PublicInbox::Import>

=head1 CONTACT

All feedback welcome via plain-text mail to L<mailto:meta@public-inbox.org>

The mail archives are hosted at L<https://public-inbox.org/meta/>

=head1 COPYRIGHT

Copyright (C) 2016 all contributors L<mailto:meta@public-inbox.org>

License: AGPL-3.0+ L<http://www.gnu.org/licenses/agpl-3.0.txt>

=cut
