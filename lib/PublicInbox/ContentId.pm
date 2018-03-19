# Copyright (C) 2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

package PublicInbox::ContentId;
use strict;
use warnings;
use base qw/Exporter/;
our @EXPORT_OK = qw/content_id content_digest/;
use PublicInbox::MID qw(mids references);

# not sure if less-widely supported hash families are worth bothering with
use Digest::SHA;

sub content_digest ($) {
	my ($mime) = @_;
	my $dig = Digest::SHA->new(256);
	my $hdr = $mime->header_obj;

	# References: and In-Reply-To: get used interchangeably
	# in some "duplicates" in LKML.  We treat them the same
	# in SearchIdx, so treat them the same for this:
	my %seen;
	foreach my $mid (@{mids($hdr)}) {
		$dig->add('mid: '.$mid);
		$seen{$mid} = 1;
	}
	foreach my $mid (@{references($hdr)}) {
		next if $seen{$mid};
		$dig->add('ref: '.$mid);
	}

	# Only use Sender: if From is not present
	foreach my $h (qw(From Sender)) {
		my @v = $hdr->header_raw($h);
		if (@v) {
			$dig->add("$h: $_") foreach @v;
			last;
		}
	}

	# Content-* headers are often no-ops, so maybe we don't need them
	foreach my $h (qw(Subject Date To Cc)) {
		my @v = $hdr->header_raw($h);
		$dig->add("$h: $_") foreach @v;
	}
	$dig->add($mime->body_raw);
	$dig;
}

sub content_id ($) {
	content_digest($_[0])->digest;
}

1;
