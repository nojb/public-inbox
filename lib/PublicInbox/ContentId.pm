# Copyright (C) 2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

package PublicInbox::ContentId;
use strict;
use warnings;
use base qw/Exporter/;
our @EXPORT_OK = qw/content_id/;

# not sure if less-widely supported hash families are worth bothering with
use Digest::SHA;

# Content-* headers are often no-ops, so maybe we don't need them
my @ID_HEADERS = qw(Subject From Date To Cc);

sub content_id ($;$) {
	my ($mime, $alg) = @_;
	$alg ||= 256;
	my $dig = Digest::SHA->new($alg);
	my $hdr = $mime->header_obj;

	# References: and In-Reply-To: get used interchangeably
	# in some "duplicates" in LKML.  We treat them the same
	# in SearchIdx, so treat them the same for this:
	my @mid = $hdr->header_raw('Message-ID');
	@mid = (join(' ', @mid) =~ /<([^>]+)>/g);
	my $refs = join(' ', $hdr->header_raw('References'),
			$hdr->header_raw('In-Reply-To'));
	my @refs = ($refs =~ /<([^>]+)>/g);
	my %seen;
	foreach my $mid (@mid, @refs) {
		next if $seen{$mid};
		$dig->add($mid);
		$seen{$mid} = 1;
	}
	foreach my $h (@ID_HEADERS) {
		my @v = $hdr->header_raw($h);
		$dig->add($_) foreach @v;
	}
	$dig->add($mime->body_raw);
	'SHA-' . $dig->algorithm . ':' . $dig->hexdigest;
}

1;
