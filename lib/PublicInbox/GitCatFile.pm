# Copyright (C) 2014, Eric Wong <normalperson@yhbt.net> and all contributors
# License: GPLv2 or later (https://www.gnu.org/licenses/gpl-2.0.txt)
# This is based on code in Git.pm which is GPLv2, but modified to avoid
# dependence on environment variables for compatibility with mod_perl.
# There are also API changes to simplify our usage and data set.
package PublicInbox::GitCatFile;
use strict;
use warnings;
use IPC::Open2 qw(open2);

sub new {
	my ($class, $git_dir) = @_;
	bless { git_dir => $git_dir }, $class;
}

sub _cat_file_begin {
	my ($self) = @_;
	return if $self->{pid};
	my ($in, $out);
	my $pid = open2($in, $out, 'git', '--git-dir', $self->{git_dir},
			'cat-file', '--batch');

	$self->{pid} = $pid;
	$self->{in} = $in;
	$self->{out} = $out;
}

sub cat_file {
	my ($self, $object) = @_;

	$self->_cat_file_begin;
	print { $self->{out} } $object, "\n" or die "write error: $!\n";

	my $in = $self->{in};
	my $head = <$in>;
	$head =~ / missing$/ and return undef;
	$head =~ /^[0-9a-f]{40} \S+ (\d+)$/ or
		die "Unexpected result from git cat-file: $head\n";

	my $size = $1;
	my $bytes_left = $size;
	my $buf;
	my $rv = '';

	while ($bytes_left) {
		my $read = read($in, $buf, $bytes_left);
		defined($read) or die "read pipe failed: $!\n";
		$rv .= $buf;
		$bytes_left -= $read;
	}

	my $read = read($in, $buf, 1);
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
