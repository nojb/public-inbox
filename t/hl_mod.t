#!/usr/bin/perl -w
# Copyright (C) 2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
eval { require highlight } or
	plan skip_all => 'failed to load highlight.pm';
use_ok 'PublicInbox::HlMod';
my $hls = PublicInbox::HlMod->new;
ok($hls, 'initialized OK');
is($hls->_shebang2lang(\"#!/usr/bin/perl -w\n"), 'perl', 'perl shebang OK');
is($hls->{-ext2lang}->{'pm'}, 'perl', '.pm suffix OK');
is($hls->{-ext2lang}->{'pl'}, 'perl', '.pl suffix OK');
is($hls->_path2lang('Makefile'), 'make', 'Makefile OK');
my $str = do { local $/; open(my $fh, __FILE__); <$fh> };
my $orig = $str;

{
	my $ref = $hls->do_hl(\$str, 'foo.perl');
	is(ref($ref), 'SCALAR', 'got a scalar reference back');
	ok(utf8::valid($$ref), 'resulting string is utf8::valid');
	like($$ref, qr/I can see you!/, 'we can see ourselves in output');
	like($$ref, qr/&amp;&amp;/, 'escaped');
	my $lref = $hls->do_hl_lang(\$str, 'perl');
	is($$ref, $$lref, 'do_hl_lang matches do_hl');

	use PublicInbox::Spawn qw(which);
	if (eval { require IPC::Run } && which('w3m')) {
		require File::Temp;
		my $cmd = [ qw(w3m -T text/html -dump -config /dev/null) ];
		my ($out, $err) = ('', '');

		IPC::Run::run($cmd, \('<pre>'.$$ref.'</pre>'), \$out, \$err);
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
