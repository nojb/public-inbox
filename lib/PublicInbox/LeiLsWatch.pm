# Copyright all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

package PublicInbox::LeiLsWatch;
use strict;
use v5.10.1;

sub lei_ls_watch {
	my ($lei) = @_;
	my $cfg = $lei->_lei_cfg or return;
	my @w = (join("\n", keys %$cfg) =~ m/^watch\.(.+?)\.state$/sgm);
	$lei->puts(join("\n", @w)) if @w;
}

1;
