# Copyright (C) 2014-2018 all contributors <meta@public-inbox.org>
# License: GPLv2 or later <https://www.gnu.org/licenses/gpl-2.0.txt>
#
# Used to read files from a git repository without excessive forking.
# Used in our web interfaces as well as our -nntpd server.
# This is based on code in Git.pm which is GPLv2+, but modified to avoid
# dependence on environment variables for compatibility with mod_perl.
# There are also API changes to simplify our usage and data set.
package PublicInbox::Git;
use strict;
use warnings;
use POSIX qw(dup2);
require IO::Handle;
use PublicInbox::Spawn qw(spawn popen_rd);
use base qw(Exporter);
our @EXPORT_OK = qw(git_unquote git_quote);

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
	$_[0] =~ s/\\([\\"abfnrtv])/$GIT_ESC{$1}/g;
	$_[0] =~ s/\\([0-7]{1,3})/chr(oct($1))/ge;
	$_[0];
}

sub git_quote ($) {
	if ($_[0] =~ s/([\\"\a\b\f\n\r\t\013]|[^[:print:]])/
		      '\\'.($ESC_GIT{$1}||sprintf("%0o",ord($1)))/egs) {
		return qq{"$_[0]"};
	}
	$_[0];
}

sub new {
	my ($class, $git_dir) = @_;
	my @st;
	$st[7] = $st[10] = 0;
	# may contain {-tmp} field for File::Temp::Dir
	bless { git_dir => $git_dir, st => \@st, -git_path => {} }, $class
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
	my $old_st = $self->{st};
	# 10 - ctime, 7 - size
	return 0 if ($st[10] == $old_st->[10] && $st[7] == $old_st->[7]);
	$self->{st} = \@st;
}

sub last_check_err {
	my ($self) = @_;
	my $fh = $self->{err_c} or return;
	sysseek($fh, 0, 0) or fail($self, "sysseek failed: $!");
	defined(sysread($fh, my $buf, -s $fh)) or
			fail($self, "sysread failed: $!");
	$buf;
}

sub _bidi_pipe {
	my ($self, $batch, $in, $out, $pid, $err) = @_;
	if ($self->{$pid}) {
		if (defined $err) { # "err_c"
			my $fh = $self->{$err};
			sysseek($fh, 0, 0) or fail($self, "sysseek failed: $!");
			truncate($fh, 0) or fail($self, "truncate failed: $!");
		}
		return;
	}
	my ($in_r, $in_w, $out_r, $out_w);

	pipe($in_r, $in_w) or fail($self, "pipe failed: $!");
	pipe($out_r, $out_w) or fail($self, "pipe failed: $!");
	if ($^O eq 'linux') { # 1031: F_SETPIPE_SZ
		fcntl($out_w, 1031, 4096);
		fcntl($in_w, 1031, 4096) if $batch eq '--batch-check';
	}

	my @cmd = (qw(git), "--git-dir=$self->{git_dir}",
			qw(-c core.abbrev=40 cat-file), $batch);
	my $redir = { 0 => fileno($out_r), 1 => fileno($in_w) };
	if ($err) {
		open(my $fh, '+>', undef) or fail($self, "open.err failed: $!");
		$self->{$err} = $fh;
		$redir->{2} = fileno($fh);
	}
	my $p = spawn(\@cmd, undef, $redir);
	defined $p or fail($self, "spawn failed: $!");
	$self->{$pid} = $p;
	$out_w->autoflush(1);
	$self->{$out} = $out_w;
	$self->{$in} = $in_r;
}

sub cat_file {
	my ($self, $obj, $ref) = @_;
	my ($retried, $in, $head);

again:
	batch_prepare($self);
	$self->{out}->print($obj, "\n") or fail($self, "write error: $!");

	$in = $self->{in};
	local $/ = "\n";
	$head = $in->getline;
	if ($head =~ / missing$/) {
		if (!$retried && alternates_changed($self)) {
			$retried = 1;
			cleanup($self);
			goto again;
		}
		return;
	}
	$head =~ /^[0-9a-f]{40} \S+ ([0-9]+)$/ or
		fail($self, "Unexpected result from git cat-file: $head");

	my $size = $1;
	my $ref_type = $ref ? ref($ref) : '';

	my $rv;
	my $left = $size;
	$$ref = $size if ($ref_type eq 'SCALAR');
	my $cb_err;

	if ($ref_type eq 'CODE') {
		$rv = eval { $ref->($in, \$left) };
		$cb_err = $@;
		# drain the rest
		my $max = 8192;
		while ($left > 0) {
			my $r = read($in, my $x, $left > $max ? $max : $left);
			defined($r) or fail($self, "read failed: $!");
			$r == 0 and fail($self, 'exited unexpectedly');
			$left -= $r;
		}
	} else {
		my $offset = 0;
		my $buf = '';
		while ($left > 0) {
			my $r = read($in, $buf, $left, $offset);
			defined($r) or fail($self, "read failed: $!");
			$r == 0 and fail($self, 'exited unexpectedly');
			$left -= $r;
			$offset += $r;
		}
		$rv = \$buf;
	}

	my $r = read($in, my $buf, 1);
	defined($r) or fail($self, "read failed: $!");
	fail($self, 'newline missing after blob') if ($r != 1 || $buf ne "\n");
	die $cb_err if $cb_err;

	$rv;
}

sub batch_prepare ($) { _bidi_pipe($_[0], qw(--batch in out pid)) }

sub check {
	my ($self, $obj) = @_;
	_bidi_pipe($self, qw(--batch-check in_c out_c pid_c err_c));
	$self->{out_c}->print($obj, "\n") or fail($self, "write error: $!");
	local $/ = "\n";
	chomp(my $line = $self->{in_c}->getline);
	my ($hex, $type, $size) = split(' ', $line);

	# Future versions of git.git may show 'ambiguous', but for now,
	# we must handle 'dangling' below (and maybe some other oddball
	# stuff):
	# https://public-inbox.org/git/20190118033845.s2vlrb3wd3m2jfzu@dcvr/T/
	return if $type eq 'missing' || $type eq 'ambiguous';

	if ($hex eq 'dangling' || $hex eq 'notdir' || $hex eq 'loop') {
		$size = $type + length("\n");
		my $r = read($self->{in_c}, my $buf, $size);
		defined($r) or fail($self, "read failed: $!");
		return;
	}

	($hex, $type, $size);
}

sub _destroy {
	my ($self, $in, $out, $pid, $err) = @_;
	my $p = delete $self->{$pid} or return;
	delete @$self{($in, $out)};
	delete $self->{$err} if $err; # `err_c'
	waitpid $p, 0;
}

sub fail {
	my ($self, $msg) = @_;
	cleanup($self);
	die $msg;
}

sub popen {
	my ($self, @cmd) = @_;
	@cmd = ('git', "--git-dir=$self->{git_dir}", @cmd);
	popen_rd(\@cmd);
}

sub qx {
	my ($self, @cmd) = @_;
	my $fh = $self->popen(@cmd);
	defined $fh or return;
	local $/ = "\n";
	return <$fh> if wantarray;
	local $/;
	<$fh>
}

# returns true if there are pending "git cat-file" processes
sub cleanup {
	my ($self) = @_;
	_destroy($self, qw(in out pid));
	_destroy($self, qw(in_c out_c pid_c err_c));
	!!($self->{pid} || $self->{pid_c});
}

# assuming a well-maintained repo, this should be a somewhat
# accurate estimation of its size
# TODO: show this in the WWW UI as a hint to potential cloners
sub packed_bytes {
	my ($self) = @_;
	my $n = 0;
	my $pack_dir = git_path($self, 'objects/pack');
	foreach my $p (glob("$pack_dir/*.pack")) {
		$n += -s $p;
	}
	$n
}

sub DESTROY { cleanup(@_) }

sub local_nick ($) {
	my ($self) = @_;
	my $ret = '???';
	# don't show full FS path, basename should be OK:
	if ($self->{git_dir} =~ m!/([^/]+)(?:/\.git)?\z!) {
		$ret = "/path/to/$1";
	}
	wantarray ? ($ret) : $ret;
}

# show the blob URL for cgit/gitweb/whatever
sub src_blob_url {
	my ($self, $oid) = @_;
	# blob_url_format = "https://example.com/foo.git/blob/%s"
	if (my $bfu = $self->{blob_url_format}) {
		return map { sprintf($_, $oid) } @$bfu if wantarray;
		return sprintf($bfu->[0], $oid);
	}
	local_nick($self);
}

sub host_prefix_url ($$) {
	my ($env, $url) = @_;
	return $url if index($url, '//') >= 0;
	my $scheme = $env->{'psgi.url_scheme'};
	my $host_port = $env->{HTTP_HOST} ||
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

sub commit_title ($$) {
	my ($self, $oid) = @_; # PublicInbox::Git, $sha1hex
	my $buf = cat_file($self, $oid) or return;
	utf8::decode($$buf);
	($$buf =~ /\r?\n\r?\n([^\r\n]+)\r?\n?/)[0]
}

# returns the modified time of a git repo, same as the "modified" field
# of a grokmirror manifest
sub modified ($) {
	my ($self) = @_;
	my $modified = 0;
	my $fh = popen($self, qw(rev-parse --branches));
	defined $fh or return $modified;
	local $/ = "\n";
	foreach my $oid (<$fh>) {
		chomp $oid;
		my $buf = cat_file($self, $oid) or next;
		$$buf =~ /^committer .*?> ([0-9]+) [\+\-]?[0-9]+/sm or next;
		my $cmt_time = $1;
		$modified = $cmt_time if $cmt_time > $modified;
	}
	$modified || time;
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
