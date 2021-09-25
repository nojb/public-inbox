# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# "lei ls-external" command
package PublicInbox::LeiLsExternal;
use strict;
use v5.10.1;

# TODO: does this need JSON output?
sub lei_ls_external {
	my ($lei, $filter) = @_;
	my $do_glob = !$lei->{opt}->{globoff}; # glob by default
	my ($OFS, $ORS) = $lei->{opt}->{z} ? ("\0", "\0\0") : (" ", "\n");
	$filter //= '*';
	my $re = $do_glob ? $lei->glob2re($filter) : undef;
	$re //= index($filter, '/') < 0 ?
			qr!/\Q$filter\E/?\z! : # exact basename match
			qr/\Q$filter\E/; # grep -F semantics
	my @ext = $lei->externals_each(my $boost = {});
	@ext = $lei->{opt}->{'invert-match'} ? grep(!/$re/, @ext)
					: grep(/$re/, @ext);
	if ($lei->{opt}->{'local'} && !$lei->{opt}->{remote}) {
		@ext = grep(!m!\A[a-z\+]+://!, @ext);
	} elsif ($lei->{opt}->{remote} && !$lei->{opt}->{'local'}) {
		@ext = grep(m!\A[a-z\+]+://!, @ext);
	}
	for my $loc (@ext) {
		$lei->out($loc, $OFS, 'boost=', $boost->{$loc}, $ORS);
	}
}

1;
