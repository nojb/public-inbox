# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
package PublicInbox::MsgIter;
use strict;
use warnings;
use base qw(Exporter);
our @EXPORT = qw(msg_iter);

# Like Email::MIME::walk_parts, but this is:
# * non-recursive
# * passes depth and indices to the iterator callback
sub msg_iter ($$) {
	my ($mime, $cb) = @_;
	my @parts = $mime->subparts;
	if (@parts) {
		my $i = 0;
		@parts = map { [ $_, 1, ++$i ] } @parts;
		while (my $p = shift @parts) {
			my ($part, $depth, @idx) = @$p;
			my @sub = $part->subparts;
			if (@sub) {
				$depth++;
				$i = 0;
				@sub = map { [ $_, $depth, @idx, ++$i ] } @sub;
				@parts = (@sub, @parts);
			} else {
				$cb->($p);
			}
		}
	} else {
		$cb->([$mime, 0, 0]);
	}
}

1;
