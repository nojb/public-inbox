#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
use PublicInbox::Smsg;
my $doc1 = eml_load('t/plack-qp.eml');
$doc1->header_set('Date', PublicInbox::Smsg::date({ds => time - (86400 * 5)}));
my $doc2 = eml_load('t/utf8.eml');
$doc2->header_set('Date', PublicInbox::Smsg::date({ds => time - (86400 * 4)}));
my $doc3 = eml_load('t/msg_iter-order.eml');
$doc3->header_set('Date', PublicInbox::Smsg::date({ds => time - (86400 * 4)}));

my $pre_existing = <<'EOF';
From x Mon Sep 17 00:00:00 2001
Message-ID: <import-before@example.com>
Subject: pre-existing
Date: Sat, 02 Oct 2010 00:00:00 +0000

blah
EOF

test_lei(sub {
	my $home = $ENV{HOME};
	my $in = $doc1->as_string;
	lei_ok [qw(import -q -F eml -)], undef, { 0 => \$in, %$lei_opt };
	lei_ok qw(q -q --save z:0.. d:last.week..), '-o', "$home/md/";
	my %before = map { $_ => 1 } glob("$home/md/cur/*");
	is_deeply(eml_load((keys %before)[0]), $doc1, 'doc1 matches');

	my @s = glob("$home/.local/share/lei/saved-searches/md-*");
	is(scalar(@s), 1, 'got one saved search');
	my $cfg = PublicInbox::Config->new("$s[0]/lei.saved-search");
	is_deeply($cfg->{'lei.q'}, ['z:0..', 'd:last.week..'],
		'store relative time, not parsed (absolute) timestamp');

	# ensure "lei up" works, since it compliments "lei q --save"
	$in = $doc2->as_string;
	lei_ok [qw(import -q -F eml -)], undef, { 0 => \$in, %$lei_opt };
	opendir my $dh, '.' or xbail "opendir .: $!";
	lei_ok qw(up -q md -C), $home;
	lei_ok qw(up -q . -C), "$home/md";
	lei_ok qw(up -q), "/$home/md";
	chdir($dh) or xbail "fchdir . $!";
	my %after = map { $_ => 1 } glob("$home/md/cur/*");
	is(delete $after{(keys(%before))[0]}, 1, 'original message kept');
	is(scalar(keys %after), 1, 'one new message added');
	is_deeply(eml_load((keys %after)[0]), $doc2, 'doc2 matches');

	# check stdin
	lei_ok [qw(q --save - -o), "mboxcl2:mbcl2" ],
		undef, { -C => $home, %$lei_opt, 0 => \'d:last.week..'};
	@s = glob("$home/.local/share/lei/saved-searches/mbcl2-*");
	$cfg = PublicInbox::Config->new("$s[0]/lei.saved-search");
	is_deeply $cfg->{'lei.q'}, 'd:last.week..',
		'q --stdin stores relative time';
	my $size = -s "$home/mbcl2";
	ok(defined($size) && $size > 0, 'results written');
	lei_ok([qw(up mbcl2)], undef, { -C => $home, %$lei_opt });
	is(-s "$home/mbcl2", $size, 'size unchanged on noop up');

	$in = $doc3->as_string;
	lei_ok [qw(import -q -F eml -)], undef, { 0 => \$in, %$lei_opt };
	lei_ok([qw(up mbcl2)], undef, { -C => $home, %$lei_opt });
	ok(-s "$home/mbcl2" > $size, 'size increased after up');

	ok(!lei(qw(up -q), $home), 'up fails w/o --save');

	lei_ok qw(ls-search); my @d = split(/\n/, $lei_out);
	lei_ok qw(ls-search -z); my @z = split(/\0/, $lei_out);
	is_deeply(\@d, \@z, '-z output matches non-z');
	is_deeply(\@d, [ "$home/mbcl2", "$home/md/" ],
		'ls-search output alphabetically sorted');
	lei_ok qw(ls-search -l);
	my $json = PublicInbox::Config->json->decode($lei_out);
	ok($json && $json->[0]->{output}, 'JSON has output');
	lei_ok qw(_complete lei up);
	like($lei_out, qr!^\Q$home/mbcl2\E$!sm, 'complete got mbcl2 output');
	like($lei_out, qr!^\Q$home/md/\E$!sm, 'complete got maildir output');

	unlink("$home/mbcl2") or xbail "unlink $!";
	lei_ok qw(_complete lei up);
	like($lei_out, qr!^\Q$home/mbcl2\E$!sm,
		'mbcl2 output shown despite unlink');
	lei_ok([qw(up mbcl2)], undef, { -C => $home, %$lei_opt });
	ok(-f "$home/mbcl2"  && -s _ == 0, 'up recreates on missing output');

	# no --augment
	open my $mb, '>', "$home/mbrd" or xbail "open $!";
	print $mb $pre_existing;
	close $mb or xbail "close: $!";
	lei_ok(qw(q --save -o mboxrd:mbrd m:qp@example.com -C), $home);
	chdir($dh) or xbail "fchdir . $!";
	open $mb, '<', "$home/mbrd" or xbail "open $!";
	is_deeply([grep(/pre-existing/, <$mb>)], [],
		'pre-existing messsage gone w/o augment');
	close $mb;
	lei_ok(qw(q m:import-before@example.com));
	is(json_utf8->decode($lei_out)->[0]->{'s'},
		'pre-existing', '--save imported before clobbering');

	# --augment
	open $mb, '>', "$home/mbrd-aug" or xbail "open $!";
	print $mb $pre_existing;
	close $mb or xbail "close: $!";
	lei_ok(qw(q -a --save -o mboxrd:mbrd-aug m:qp@example.com -C), $home);
	chdir($dh) or xbail "fchdir . $!";
	open $mb, '<', "$home/mbrd-aug" or xbail "open $!";
	$mb = do { local $/; <$mb> };
	like($mb, qr/pre-existing/, 'pre-existing message preserved w/ -a');
	like($mb, qr/<qp\@example\.com>/, 'new result written w/ -a');
});
done_testing;
