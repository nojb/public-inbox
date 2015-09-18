# Copyright (C) 2015 all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
use strict;
use warnings;
use Test::More;
use Data::Dumper;

use_ok 'PublicInbox::NNTP';

{
	sub quote_str {
		my (undef, $s) = split(/ = /, Dumper($_[0]), 2);
		$s =~ s/;\n//;
		$s;
	}

	sub wm_prepare {
		my ($wm) = @_;
		my $orig = qq{'$wm'};
		PublicInbox::NNTP::wildmat2re($_[0]);
		my $new = quote_str($_[0]);
		($orig, $new);
	}

	sub wildmat_like {
		my ($str, $wm) = @_;
		my ($orig, $new) = wm_prepare($wm);
		like($str, $wm, "$orig matches '$str' using $new");
	}

	sub wildmat_unlike {
		my ($str, $wm, $check_ex) = @_;
		if ($check_ex) {
			use re 'eval';
			my $re = qr/$wm/;
			like($str, $re, "normal re with $wm matches, but ...");
		}
		my ($orig, $new) = wm_prepare($wm);
		unlike($str, $wm, "$orig does not match '$str' using $new");
	}

	wildmat_like('[foo]', '[\[foo\]]');
	wildmat_like('any', '*');
	wildmat_unlike('bar.foo.bar', 'foo.*');

	# no code execution
	wildmat_unlike('HI', '(?{"HI"})', 1);
	wildmat_unlike('HI', '[(?{"HI"})]', 1);
}

{
	sub ngpat_like {
		my ($str, $pat) = @_;
		my $orig = $pat;
		PublicInbox::NNTP::ngpat2re($pat);
		like($str, $pat, "'$orig' matches '$str' using $pat");
	}

	ngpat_like('any', '*');
	ngpat_like('a.s.r', 'a.t,a.s.r');
	ngpat_like('a.s.r', 'a.t,a.s.*');
}

done_testing();
