# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# deal with the lack of URI::nntps in upstream URI.
# nntps is IANA registered, snews is deprecated
# cf. https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=983419
# Fixed in URI 5.08, we can drop this by 2035 when LTS distros all have it
package PublicInbox::URInntps;
use strict;
use parent qw(URI::snews);
use URI;

sub new {
	my ($class, $url) = @_;
	$url =~ m!\Anntps://!i ? bless(\$url, $class) : URI->new($url);
}

1;
