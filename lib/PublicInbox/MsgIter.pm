# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
package PublicInbox::MsgIter;
use strict;
use warnings;
use base qw(Exporter);
our @EXPORT = qw(msg_iter);
use Email::MIME;
use Scalar::Util qw(readonly);

# Workaround Email::MIME versions without
# commit dcef9be66c49ae89c7a5027a789bbbac544499ce
# ("removing all trailing newlines was too much")
# This is necessary for Debian jessie
my $bad = 1.923;
my $good = 1.935;
my $ver = $Email::MIME::VERSION;
my $extra_nl = 1 if ($ver >= $bad && $ver < $good);

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
				if ($extra_nl) {
					my $lf = $part->{mycrlf};
					my $bref = $part->{body};
					if (readonly($$bref)) {
						my $s = $$bref . $lf;
						$part->{body} = \$s;
					} else {
						$$bref .= $lf;
					}
				}
				$cb->($p);
			}
		}
	} else {
		$cb->([$mime, 0, 0]);
	}
}

1;
