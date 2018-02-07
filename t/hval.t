# Copyright (C) 2017-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use_ok 'PublicInbox::Hval';

my $ibx = {
	-no_obfuscate_re => qr/(?:example\.com)\z/i,
	-no_obfuscate => {
		'meta@public-inbox.org' => 1,
	}
};

my $html = <<'EOF';
hello@example.comm
hello@example.com
meta@public-inbox.org
test@public-inbox.org
test@a.b.c.org
te.st@example.org
EOF

PublicInbox::Hval::obfuscate_addrs($ibx, $html);

my $exp = <<'EOF';
hello@example&#8226;comm
hello@example.com
meta@public-inbox.org
test@public-inbox&#8226;org
test@a&#8226;b.c.org
te.st@example&#8226;org
EOF

is($html, $exp, 'only obfuscated relevant addresses');

is('foo-bar', PublicInbox::Hval::to_filename('foo bar  '),
	'to_filename has no trailing -');

is('foo-bar', PublicInbox::Hval::to_filename("foo   bar\nanother line\n"),
	'to_filename has no repeated -, and nothing past LF');

is('foo.bar', PublicInbox::Hval::to_filename("foo....bar"),
	'to_filename squeezes -');


done_testing();
