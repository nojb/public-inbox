# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Maildirs for now, MH eventually
package PublicInbox::MdirReader;
use strict;
use v5.10.1;

sub maildir_each_file ($$;@) {
	my ($dir, $cb, @arg) = @_;
	$dir .= '/' unless substr($dir, -1) eq '/';
	for my $d (qw(new/ cur/)) {
		my $pfx = $dir.$d;
		opendir my $dh, $pfx or next;
		while (defined(my $fn = readdir($dh))) {
			$cb->($pfx.$fn, @arg) if $fn =~ /:2,[A-Za-z]*\z/;
		}
	}
}

1;
