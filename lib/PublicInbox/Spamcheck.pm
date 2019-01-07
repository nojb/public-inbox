# Copyright (C) 2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Spamchecking used by -watch and -mda tools
package PublicInbox::Spamcheck;
use strict;
use warnings;

sub get {
	my ($config, $key, $default) = @_;
	my $spamcheck = $config->{$key};
	$spamcheck = $default unless $spamcheck;

	return if !$spamcheck || $spamcheck eq 'none';

	if ($spamcheck eq 'spamc') {
		$spamcheck = 'PublicInbox::Spamcheck::Spamc';
	}
	if ($spamcheck =~ /::/) {
		eval "require $spamcheck";
		return $spamcheck->new;
	}
	warn "unsupported $key=$spamcheck\n";
	undef;
}

1;
