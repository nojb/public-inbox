# Copyright (C) 2014, Eric Wong <normalperson@yhbt.net> and all contributors
# License: GPLv2 or later (https://www.gnu.org/licenses/gpl-2.0.txt)
# This is based on code in Git.pm which is GPLv2, but modified to avoid
# dependence on environment variables for compatibility with mod_perl.
# There are also API changes to simplify our usage and data set.
package PublicInbox::GitCatFile;
use strict;
use warnings;
use Fcntl qw(F_GETFD F_SETFD FD_CLOEXEC);
use POSIX qw(dup2);

sub new {
	my ($class, $git_dir) = @_;
	bless { git_dir => $git_dir }, $class;
}

sub set_cloexec {
	my ($fh) = @_;
	my $flags = fcntl($fh, F_GETFD, 0) or die "fcntl(F_GETFD): $!\n";
	fcntl($fh, F_SETFD, $flags | FD_CLOEXEC) or die "fcntl(F_SETFD): $!\n";
}

sub _cat_file_begin {
	my ($self) = @_;
	return if $self->{pid};
	my ($in_r, $in_w, $out_r, $out_w);

	pipe($in_r, $in_w) or die "pipe failed: $!\n";
	set_cloexec($_) foreach ($in_r, $in_w);
	pipe($out_r, $out_w) or die "pipe failed: $!\n";
	set_cloexec($_) foreach ($out_r, $out_w);

	my @cmd = ('git', "--git-dir=$self->{git_dir}", qw(cat-file --batch));
	my $pid = fork;
	defined $pid or die "fork failed: $!\n";
	if ($pid == 0) {
		dup2(fileno($out_r), 0) or die "redirect stdin failed: $!\n";
		dup2(fileno($in_w), 1) or die "redirect stdout failed: $!\n";
		exec(@cmd) or die 'exec `' . join(' '). "' failed: $!\n";
	}
	close $out_r or die "close failed: $!\n";
	close $in_w or die "close failed: $!\n";

	$self->{in} = $in_r;
	$self->{out} = $out_w;
	$self->{pid} = $pid;
}

sub cat_file {
	my ($self, $object) = @_;

	$object .= "\n";
	my $len = bytes::length($object);

	$self->_cat_file_begin;
	my $written = syswrite($self->{out}, $object);
	if (!defined $written) {
		die "pipe write error: $!\n";
	} elsif ($written != $len) {
		die "wrote too little to pipe ($written < $len)\n";
	}

	my $in = $self->{in};
	my $head = <$in>;
	$head =~ / missing$/ and return undef;
	$head =~ /^[0-9a-f]{40} \S+ (\d+)$/ or
		die "Unexpected result from git cat-file: $head\n";

	my $size = $1;
	my $bytes_left = $size;
	my $offset = 0;
	my $rv = '';

	while ($bytes_left) {
		my $read = read($in, $rv, $bytes_left, $offset);
		defined($read) or die "sysread pipe failed: $!\n";
		$bytes_left -= $read;
		$offset += $read;
	}

	my $read = read($in, my $buf, 1);
	defined($read) or die "read pipe failed: $!\n";
	if ($read != 1 || $buf ne "\n") {
		die "newline missing after blob\n";
	}
	\$rv;
}

sub DESTROY {
	my ($self) = @_;
	my $pid = $self->{pid} or return;
	$self->{pid} = undef;
	foreach my $f (qw(in out)) {
		my $fh = $self->{$f};
		defined $fh or next;
		close $fh;
		$self->{$f} = undef;
	}
	waitpid $pid, 0;
}

1;
