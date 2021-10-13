# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# "lei forget-external" command
package PublicInbox::LeiForgetExternal;
use strict;
use v5.10.1;

sub lei_forget_external {
	my ($lei, @locations) = @_;
	my $cfg = $lei->_lei_cfg or
		return $lei->fail('no externals configured');
	my %seen;
	for my $loc (@locations) {
		for my $l ($loc, $lei->ext_canonicalize($loc)) {
			next if $seen{$l}++;
			my $key = "external.$l.boost";
			delete($cfg->{$key});
			$lei->_config('--unset', $key);
			if ($? == 0) {
				$lei->qerr("# $l forgotten ");
			} elsif (($? >> 8) == 5) {
				warn("# $l not found\n");
			} else {
				$lei->child_error($?, "# --unset $key error");
			}
		}
	}
}

# shell completion helper called by lei__complete
sub _complete_forget_external {
	my ($lei, @argv) = @_;
	my $cfg = $lei->_lei_cfg or return ();
	my ($cur, $re, $match_cb) = $lei->complete_url_prepare(\@argv);
	# FIXME: bash completion off "http:" or "https:" when the last
	# character is a colon doesn't work properly even if we're
	# returning "//$HTTP_HOST/$PATH_INFO/", not sure why, could
	# be a bash issue.
	map {
		$match_cb->(substr($_, length('external.')));
	} grep(/\Aexternal\.$re\Q$cur/, @{$cfg->{-section_order}});
}

1;
