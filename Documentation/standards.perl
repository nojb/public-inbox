#!/usr/bin/perl -w
use strict;
# Copyright 2019-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

print <<EOF;
Relevant standards for public-inbox users and hackers
-----------------------------------------------------

Non-exhaustive list of standards public-inbox software attempts or
intends to implement.  This list is intended to be a quick reference
for hackers and users.

Given the goals of interoperability and accessibility; strict
conformance to standards is not always possible, but rather
best-effort taking into account real-world cases.  In particular,
"obsolete" standards remain relevant as long as clients and
data exists.

IETF RFCs
---------

EOF

my $rfcs = [
	3977 => 'NNTP',
	977 => 'NNTP (old)',
	1036 => 'Standard for Interchange of USENET Messages',
	5536 => 'Netnews Article Format',
	5537 => 'Netnews Architecture and Protocols',
	1738 => 'Uniform resource locators',
	5092 => 'IMAP URL scheme',
	5538 => 'NNTP URI schemes',
	6048 => 'NNTP additions to LIST command (TODO)',
	8054 => 'NNTP compression',
	4642 => 'NNTP TLS',
	8143 => 'NNTP TLS',
	2980 => 'NNTP extensions (obsolete, but NOT irrelevant)',
	4287 => 'Atom syndication',
	4685 => 'Atom threading extensions',
	2919 => 'List-Id mail header',
	5064 => 'Archived-At mail header',
	3986 => 'URI escaping',
	1521 => 'MIME extensions',
	2616 => 'HTTP/1.1 (newer updates should apply, too)',
	7230 => 'HTTP/1.1 message syntax and routing',
	7231 => 'HTTP/1.1 semantics and content',
	822 => 'Internet message format (1982)',
	2822 => 'Internet message format (2001)',
	5322 => 'Internet message format (2008)',
	3501 => 'IMAP4rev1',
	2177 => 'IMAP IDLE',
	2683 => 'IMAP4 Implementation Recommendations',
	# 5032 = 'WITHIN search extension for IMAP',
	4978 => 'IMAP COMPRESS Extension',
	# 5182 = 'IMAP Extension for Referencing the Last SEARCH Result',
	# 5256 => 'IMAP SORT and THREAD extensions',
	# 5738 =>  'IMAP Support for UTF-8',
	# 8474 => 'IMAP Extension for Object Identifiers',

	# 8620 => JSON Meta Application Protocol (JMAP)
	# 8621 => JSON Meta Application Protocol (JMAP) for Mail
	# ...

	# examples/unsubscribe.milter and PublicInbox::Unsubscribe
	2369 => 'URLs as Meta-Syntax for Core Mail List Commands',
	8058 => 'Signaling One-Click Functionality for List Email Headers',

	# TODO: flesh this out

];

my @rfc_urls = qw(tools.ietf.org/html/rfc%d
		  www.rfc-editor.org/errata_search.php?rfc=%d);

for (my $i = 0; $i < $#$rfcs;) {
	my $num = $rfcs->[$i++];
	my $txt = $rfcs->[$i++];
	print "rfc$num\t- $txt\n";

	printf "\thttps://$_\n", $num foreach @rfc_urls;
	print "\n";
}

print <<'EOF'
Other relevant documentation
----------------------------

* IMAP capabilities registry and response codes:
  https://www.iana.org/assignments/imap-capabilities
  https://www.iana.org/assignments/imap-response-codes

* Documentation/technical/http-protocol.txt in git source code:
  https://public-inbox.org/git/9c5b6f0fac/s

* Various mbox formats (we currently emit and parse mboxrd)
  https://en.wikipedia.org/wiki/Mbox

* PSGI/Plack specifications (as long as our web frontend uses Perl5)
  git clone https://github.com/plack/psgi-specs.git

Copyright
---------

Copyright (C) 2019-2020 all contributors <meta@public-inbox.org>
License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
EOF
