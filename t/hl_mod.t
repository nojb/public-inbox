#!/usr/bin/perl -w
# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon; use IO::Handle; # ->autoflush
use Fcntl qw(:seek);
require_mods 'highlight';
use_ok 'PublicInbox::HlMod';
my $hls = PublicInbox::HlMod->new;
ok($hls, 'initialized OK');
is($hls->_shebang2lang(\"#!/usr/bin/perl -w\n"), 'perl', 'perl shebang OK');
is($hls->{-ext2lang}->{'pm'}, 'perl', '.pm suffix OK');
is($hls->{-ext2lang}->{'pl'}, 'perl', '.pl suffix OK');
like($hls->_path2lang('Makefile'), qr/\Amake/, 'Makefile OK');
my $str = do { local $/; open(my $fh, '<', __FILE__); <$fh> };
my $orig = $str;

{
	my $ref = $hls->do_hl(\$str, 'foo.perl');
	is(ref($ref), 'SCALAR', 'got a scalar reference back');
	ok(utf8::valid($$ref), 'resulting string is utf8::valid');
	like($$ref, qr/I can see you!/, 'we can see ourselves in output');
	like($$ref, qr/&amp;&amp;/, 'escaped &&');
	my $lref = $hls->do_hl_lang(\$str, 'perl');
	is($$ref, $$lref, 'do_hl_lang matches do_hl');

	SKIP: {
		my $w3m = require_cmd('w3m', 1) or
			skip('w3m(1) missing to check output', 1);
		my $cmd = [ $w3m, qw(-T text/html -dump -config /dev/null) ];
		my $in = '<pre>' . $$ref . '</pre>';
		my $out = xqx($cmd, undef, { 0 => \$in });
		# expand tabs and normalize whitespace,
		# w3m doesn't preserve tabs
		$orig =~ s/\t/        /gs;
		$out =~ s/\s*\z//sg;
		$orig =~ s/\s*\z//sg;
		is($out, $orig, 'w3m output matches');
	}
}

if ('experimental, only for help text') {
	my $tmp = <<'EOF';
:>
```perl
my $foo = 1 & 2;
```
:<
EOF
	$hls->do_hl_text(\$tmp);
	my @hl = split(/^/m, $tmp);
	is($hl[0], ":&gt;\n", 'first line escaped');
	is($hl[1], "```perl\n", '2nd line preserved');
	like($hl[2], qr/<span\b/, 'code highlighted');
	like($hl[2], qr/&amp;/, 'ampersand escaped');
	is($hl[3], "```\n", '4th line preserved');
	is($hl[4], ":&lt;\n", '5th line escaped');
	is(scalar(@hl), 5, 'no extra line');

}

done_testing;
