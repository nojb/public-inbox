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
my @ID_HEADERS = qw(Subject From Date Message-ID References To Cc In-Reply-To);

sub content_id ($;$) {
	my ($mime, $alg) = @_;
	$alg ||= 256;
	my $dig = Digest::SHA->new($alg);
	my $hdr = $mime->header_obj;

	foreach my $h (@ID_HEADERS) {
		my @v = $hdr->header_raw($h);
		$dig->add($_) foreach @v;
	}
	$dig->add($mime->body_raw);
	'SHA-' . $dig->algorithm . ':' . $dig->hexdigest;
}

1;
