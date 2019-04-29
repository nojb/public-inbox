#!/usr/bin/perl -w
use strict;
# Copyright 2019 all contributors <meta@public-inbox.org>
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
	6048 => 'NNTP additions to LIST command (TODO)',
	8054 => 'NNTP compression (TODO)',
	4642 => 'NNTP TLS (TODO)',
	8143 => 'NNTP TLS (TODO)',
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
	2822 => 'Internet message format',
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

* Documentation/technical/http-protocol.txt in git source code:
  https://public-inbox.org/git/9c5b6f0fac/s

* Various mbox formats (we currently emit and parse mboxrd)
  https://en.wikipedia.org/wiki/Mbox

* PSGI/Plack specifications (as long as our web frontend uses Perl5)
  git clone https://github.com/plack/psgi-specs.git

Copyright
---------

Copyright 2019 all contributors <meta@public-inbox.org>
License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
EOF
