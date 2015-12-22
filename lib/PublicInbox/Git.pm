# Copyright (C) 2014-2015 all contributors <meta@public-inbox.org>
# License: GPLv2 or later (https://www.gnu.org/licenses/gpl-2.0.txt)
#
# Used to read files from a git repository without excessive forking.
# Used in our web interfaces as well as our -nntpd server.
# This is based on code in Git.pm which is GPLv2, but modified to avoid
# dependence on environment variables for compatibility with mod_perl.
# There are also API changes to simplify our usage and data set.
package PublicInbox::Git;
use strict;
use warnings;
use POSIX qw(dup2);
require IO::Handle;

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
	$self->{$pid} = fork;
	defined $self->{$pid} or fail($self, "fork failed: $!");
	if ($self->{$pid} == 0) {
		dup2(fileno($out_r), 0) or die "redirect stdin failed: $!\n";
		dup2(fileno($in_w), 1) or die "redirect stdout failed: $!\n";
		exec(@cmd) or die 'exec `' . join(' '). "' failed: $!\n";
	}
	close $out_r or fail($self, "close failed: $!");
	close $in_w or fail($self, "close failed: $!");
	$out_w->autoflush(1);
	$self->{$out} = $out_w;
	$self->{$in} = $in_r;
}

sub cat_file {
	my ($self, $obj, $ref) = @_;

	$self->_bidi_pipe(qw(--batch in out pid));
	$self->{out}->print($obj, "\n") or fail($self, "write error: $!");

	my $in = $self->{in};
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

sub check {
	my ($self, $obj) = @_;
	$self->_bidi_pipe(qw(--batch-check in_c out_c pid_c));
	$self->{out_c}->print($obj, "\n") or fail($self, "write error: $!");
	chomp(my $line = $self->{in_c}->getline);
	my ($hex, $type, $size) = split(' ', $line);
	return if $type eq 'missing';
	($hex, $type, $size);
}

sub _destroy {
	my ($self, $in, $out, $pid) = @_;
	my $p = $self->{$pid} or return;
	$self->{$pid} = undef;
	foreach my $f ($in, $out) {
		my $fh = $self->{$f};
		defined $fh or next;
		close $fh;
		$self->{$f} = undef;
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
	my $mode = '-|';
	$mode = shift @cmd if ($cmd[0] eq '|-');
	@cmd = ('git', "--git-dir=$self->{git_dir}", @cmd);
	my $pid = open my $fh, $mode, @cmd or
		die('open `'.join(' ', @cmd) . " pipe failed: $!\n");
	$fh;
}

sub cleanup {
	my ($self) = @_;
	_destroy($self, qw(in out pid));
	_destroy($self, qw(in_c out_c pid_c));
}

sub DESTROY { cleanup(@_) }

1;
