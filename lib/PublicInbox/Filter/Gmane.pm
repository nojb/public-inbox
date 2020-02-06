# Copyright (C) 2018-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Filter for importing some archives from gmane
package PublicInbox::Filter::Gmane;
use base qw(PublicInbox::Filter::Base);
use strict;
use warnings;

sub scrub {
	my ($self, $mime) = @_;
	my $hdr = $mime->header_obj;

	# gmane rewrites Received headers, which increases spamminess
	# Some older archives set Original-To
	foreach my $x (qw(Received To)) {
		my @h = $hdr->header_raw("Original-$x");
		if (@h) {
			$hdr->header_set($x, @h);
			$hdr->header_set("Original-$x");
		}
	}

	# Approved triggers for the SA HEADER_SPAM rule,
	# X-From is gmane specific
	foreach my $drop (qw(Approved X-From)) {
		$hdr->header_set($drop);
	}

	# appears to be an old gmane bug:
	$hdr->header_set('connect()');

	$self->ACCEPT($mime);
}

sub delivery {
	my ($self, $mime) = @_;
	$self->scrub($mime);
}

1;
