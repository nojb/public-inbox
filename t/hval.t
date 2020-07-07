# Copyright (C) 2017-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use_ok 'PublicInbox::Hval', qw(to_attr);

# reverse the result of to_attr
sub from_attr ($) {
	my ($str) = @_;
	my $first = '';
	if ($str =~ s/\AZ([a-f0-9]{2})//ms) {
		$first = chr(hex($1));
	}
	$str =~ s!::([a-f0-9]{2})!chr(hex($1))!egms;
	$str =~ tr!:!/!;
	utf8::decode($str);
	$first . $str;
}

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

is(PublicInbox::Hval::to_filename('foo bar  '), 'foo-bar',
	'to_filename has no trailing -');

is(PublicInbox::Hval::to_filename("foo   bar\nanother line\n"), 'foo-bar',
	'to_filename has no repeated -, and nothing past LF');

is(PublicInbox::Hval::to_filename("foo....bar"), 'foo.bar',
	'to_filename squeezes -');

is(PublicInbox::Hval::to_filename(''), undef, 'empty string returns undef');

my $s = "\0\x07\n";
PublicInbox::Hval::src_escape($s);
is($s, "\\0\\a\n", 'src_escape works as intended');

foreach my $s ('Hello/World.pm', 'Zcat', 'hello world.c', 'Eléanor', '$at') {
	my $attr = to_attr($s);
	is(from_attr($attr), $s, "$s => $attr => $s round trips");
}

{
	my $bad = to_attr('foo//bar');
	ok(!$bad, 'double-slash rejected');
}

done_testing();
