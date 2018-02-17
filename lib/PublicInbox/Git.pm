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

sub new {
	my ($class, $git_dir) = @_;
	bless { git_dir => $git_dir }, $class
}

sub _bidi_pipe {
	my ($self, $batch, $in, $out, $pid) = @_;
	return if $self->{$pid};
	my ($in_r, $in_w, $out_r, $out_w);

	pipe($in_r, $in_w) or fail($self, "pipe failed: $!");
	pipe($out_r, $out_w) or fail($self, "pipe failed: $!");

	my @cmd = ('git', "--git-dir=$self->{git_dir}", qw(cat-file), $batch);
	my $redir = { 0 => fileno($out_r), 1 => fileno($in_w) };
	my $p = spawn(\@cmd, undef, $redir);
	defined $p or fail($self, "spawn failed: $!");
	$self->{$pid} = $p;
	$out_w->autoflush(1);
	$self->{$out} = $out_w;
	$self->{$in} = $in_r;
}

sub cat_file {
	my ($self, $obj, $ref) = @_;

	batch_prepare($self);
	$self->{out}->print($obj, "\n") or fail($self, "write error: $!");

	my $in = $self->{in};
	local $/ = "\n";
	my $head = $in->getline;
	$head =~ / missing$/ and return undef;
	$head =~ /^[0-9a-f]{40} \S+ (\d+)$/ or
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
	$self->_bidi_pipe(qw(--batch-check in_c out_c pid_c));
	$self->{out_c}->print($obj, "\n") or fail($self, "write error: $!");
	local $/ = "\n";
	chomp(my $line = $self->{in_c}->getline);
	my ($hex, $type, $size) = split(' ', $line);
	return if $type eq 'missing';
	($hex, $type, $size);
}

sub _destroy {
	my ($self, $in, $out, $pid) = @_;
	my $p = delete $self->{$pid} or return;
	foreach my $f ($in, $out) {
		delete $self->{$f};
	}
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

sub cleanup {
	my ($self) = @_;
	_destroy($self, qw(in out pid));
	_destroy($self, qw(in_c out_c pid_c));
}

# assuming a well-maintained repo, this should be a somewhat
# accurate estimation of its size
# TODO: show this in the WWW UI as a hint to potential cloners
sub packed_bytes {
	my ($self) = @_;
	my $n = 0;
	foreach my $p (glob("$self->{git_dir}/objects/pack/*.pack")) {
		$n += -s $p;
	}
	$n
}

sub DESTROY { cleanup(@_) }

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
