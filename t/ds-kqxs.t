# Copyright (C) 2019 all contributors <meta@public-inbox.org>
# Licensed the same as Danga::Socket (and Perl5)
# License: GPL-1.0+ or Artistic-1.0-Perl
#  <https://www.gnu.org/licenses/gpl-1.0.txt>
#  <https://dev.perl.org/licenses/artistic.html>
use strict;
use Test::More;
unless (eval { require IO::KQueue }) {
	my $m = $^O !~ /bsd/ ? 'DSKQXS is only for *BSD systems'
				: "no IO::KQueue, skipping $0: $@";
	plan skip_all => $m;
}
local $ENV{TEST_IOPOLLER} = 'PublicInbox::DSKQXS';
require './t/ds-poll.t';
