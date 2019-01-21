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
	like($$ref, qr/I can see you!/, 'we can see ourselves in output');

	use PublicInbox::Spawn qw(which);
	if (eval { require IPC::Run } && which('w3m')) {
		require File::Temp;
		my $cmd = [ qw(w3m -T text/html -dump -config /dev/null) ];
		my ($out, $err) = ('', '');
		IPC::Run::run($cmd, $ref, \$out, \$err);
		# expand tabs and normalize whitespace,
		# w3m doesn't preserve tabs
		$orig =~ s/\t/        /gs;
		$out =~ s/\s*\z//sg;
		$orig =~ s/\s*\z//sg;
		is($out, $orig, 'w3m output matches');
	}
}

my $nr = $ENV{TEST_MEMLEAK};
if ($nr && -r "/proc/$$/status") {
	my $fh;
	open $fh, '<', "/proc/$$/status";
	diag "starting at memtest at ".join('', grep(/VmRSS:/, <$fh>));
	PublicInbox::HlMod->new->do_hl(\$orig) for (1..$nr);
	open $fh, '<', "/proc/$$/status";
	diag "creating $nr instances: ".join('', grep(/VmRSS:/, <$fh>));
	my $hls = PublicInbox::HlMod->new;
	$hls->do_hl(\$orig) for (1..$nr);
	$hls = undef;
	open $fh, '<', "/proc/$$/status";
	diag "reused instance $nr times: ".join('', grep(/VmRSS:/, <$fh>));
}

done_testing;
