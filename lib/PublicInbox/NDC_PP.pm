# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Pure-perl class for Linux non-Inline::C users to disable COW for btrfs
package PublicInbox::NDC_PP;
use strict;
use v5.10.1;

sub set_nodatacow ($) {
	my ($fd) = @_;
	return if $^O ne 'linux';
	defined(my $path = readlink("/proc/self/fd/$fd")) or return;
	open my $mh, '<', '/proc/self/mounts' or return;
	for (grep(/ btrfs /, <$mh>)) {
		my (undef, $mnt_path, $type) = split(/ /);
		next if $type ne 'btrfs'; # in case of false-positive from grep

		# weird chars are escaped as octal
		$mnt_path =~ s/\\(0[0-9]{2})/chr(oct($1))/egs;
		$mnt_path .= '/' unless $mnt_path =~ m!/\z!;
		if (index($path, $mnt_path) == 0) {
			# error goes to stderr, but non-fatal for us
			system('chattr', '+C', $path);
			last;
		}
	}
}

1;
