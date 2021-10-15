#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
use PublicInbox::Smsg;
use List::Util qw(sum);

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
	lei_ok qw(q -q z:0.. d:last.week..), '-o', "MAILDIR:$home/md/";
	my %before = map { $_ => 1 } glob("$home/md/cur/*");
	my $f = (keys %before)[0] or xbail({before => \%before});
	is_deeply(eml_load($f), $doc1, 'doc1 matches');
	lei_ok qw(ls-mail-sync);
	is($lei_out, "maildir:$home/md\n", 'canonicalized mail sync name');

	my @s = glob("$home/.local/share/lei/saved-searches/md-*");
	is(scalar(@s), 1, 'got one saved search');
	my $cfg = PublicInbox::Config->new("$s[0]/lei.saved-search");
	is($cfg->{'lei.q.output'}, "maildir:$home/md", 'canonicalized output');
	is_deeply($cfg->{'lei.q'}, ['z:0..', 'd:last.week..'],
		'store relative time, not parsed (absolute) timestamp');

	# ensure "lei up" works, since it compliments "lei q --save"
	$in = $doc2->as_string;
	lei_ok [qw(import -q -F eml -)], undef, { 0 => \$in, %$lei_opt };
	lei_ok qw(up -q md -C), $home;
	lei_ok qw(up -q . -C), "$home/md";
	lei_ok qw(up -q), "/$home/md";
	my %after = map { $_ => 1 } glob("$home/md/{new,cur}/*");
	is(delete $after{(keys(%before))[0]}, 1, 'original message kept');
	is(scalar(keys %after), 1, 'one new message added');
	$f = (keys %after)[0] or xbail({after => \%after});
	is_deeply(eml_load($f), $doc2, 'doc2 matches');

	# check stdin
	lei_ok [qw(q - -o), "mboxcl2:mbcl2" ], undef,
		{ -C => $home, %$lei_opt, 0 => \'d:last.week..'};
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

	ok(!lei(qw(up -q), $home), 'up fails on unknown dir');
	like($lei_err, qr/--no-save was used/, 'error noted --no-save');

	lei_ok(qw(q --no-save d:last.week.. -q -o), "$home/no-save");
	ok(!lei(qw(up -q), "$home/no-save"), 'up fails on --no-save');
	like($lei_err, qr/--no-save was used/, 'error noted --no-save');

	lei_ok qw(ls-search); my @d = split(/\n/, $lei_out);
	lei_ok qw(ls-search -z); my @z = split(/\0/, $lei_out);
	is_deeply(\@d, \@z, '-z output matches non-z');
	is_deeply(\@d, [ "$home/mbcl2", "$home/md" ],
		'ls-search output alphabetically sorted');
	lei_ok qw(ls-search -l);
	my $json = PublicInbox::Config->json->decode($lei_out);
	ok($json && $json->[0]->{output}, 'JSON has output');
	lei_ok qw(_complete lei up);
	like($lei_out, qr!^\Q$home/mbcl2\E$!sm, 'complete got mbcl2 output');
	like($lei_out, qr!^\Q$home/md\E$!sm, 'complete got maildir output');

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
	lei_ok(qw(q -o mboxrd:mbrd m:qp@example.com -C), $home);
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
	lei_ok(qw(q -a -o mboxrd:mbrd-aug m:qp@example.com -C), $home);
	open $mb, '<', "$home/mbrd-aug" or xbail "open $!";
	$mb = do { local $/; <$mb> };
	like($mb, qr/pre-existing/, 'pre-existing message preserved w/ -a');
	like($mb, qr/<qp\@example\.com>/, 'new result written w/ -a');

	lei_ok(qw(up --all=local));

	ok(!lei(qw(forget-search), "$home/bogus"), 'bogus forget');
	like($lei_err, qr/--save was not used/, 'error noted --save');

	lei_ok qw(_complete lei forget-search);
	like($lei_out, qr/mbrd-aug/, 'forget-search completion');
	lei_ok(qw(forget-search -v), "$home/mbrd-aug");
	is($lei_out, '', 'no output');
	like($lei_err, qr/\bmbrd-aug\b/, '-v (verbose) reported unlinks');
	lei_ok qw(_complete lei forget-search);
	unlike($lei_out, qr/mbrd-aug/,
		'forget-search completion cleared after forget');
	ok(!lei('up', "$home/mbrd-aug"), 'lei up fails after forget');
	like($lei_err, qr/--no-save was used/, 'error noted --no-save');

	# dedupe=mid
	my $o = "$home/dd-mid";
	$in = $doc2->as_string . "\n-------\nappended list sig\n";
	lei_ok [qw(import -q -F eml -)], undef, { 0 => \$in, %$lei_opt };
	lei_ok(qw(q --dedupe=mid m:testmessage@example.com -o), $o);
	my @m = glob("$o/cur/*");
	is(scalar(@m), 1, '--dedupe=mid w/ --save');
	$in = $doc2->as_string . "\n-------\nanother list sig\n";
	lei_ok [qw(import -q -F eml -)], undef, { 0 => \$in, %$lei_opt };
	lei_ok 'up', $o;
	is_deeply([glob("$o/cur/*")], \@m, 'lei up dedupe=mid works');

	for my $dd (qw(content)) {
		$o = "$home/dd-$dd";
		lei_ok(qw(q m:testmessage@example.com -o), $o, "--dedupe=$dd");
		@m = glob("$o/cur/*");
		is(scalar(@m), 3, 'all 3 matches with dedupe='.$dd);
	}

	# dedupe=oid
	$o = "$home/dd-oid";
	my $ibx = create_inbox 'ibx', indexlevel => 'medium',
			tmpdir => "$home/v1", sub {};
	lei_ok(qw(q --dedupe=oid m:qp@example.com -o), $o,
		'-I', $ibx->{inboxdir});
	@m = glob("$o/cur/*");
	is(scalar(@m), 1, 'got first result');

	my $im = $ibx->importer(0);
	my $diff = "X-Insignificant-Header: x\n".$doc1->as_string;
	$im->add(PublicInbox::Eml->new($diff));
	$im->done;
	lei_ok('up', $o);
	@m = glob("$o/{new,cur}/*");
	is(scalar(@m), 2, 'got 2nd result due to different OID');

	SKIP: {
		symlink($o, "$home/ln -s") or
			skip "symlinks not supported in $home?: $!", 1;
		lei_ok('up', "$home/ln -s");
		lei_ok('forget-search', "$home/ln -s");
	};

	my $v2 = "$home/v2"; # v2: as an output destination
	my (@before, @after);
	require PublicInbox::MboxReader;
	lei_ok(qw(q z:0.. -o), "v2:$v2");
	like($lei_err, qr/^# ([1-9][0-9]*) written to \Q$v2\E/sm,
		'non-zero write output to stderr');
	lei_ok(qw(q z:0.. -o), "mboxrd:$home/before", '--only', $v2, '-j1,1');
	open my $fh, '<', "$home/before";
	PublicInbox::MboxReader->mboxrd($fh, sub { push @before, $_[0] });
	isnt(scalar(@before), 0, 'initial v2 written');
	my $orig = sum(map { -f $_ ? -s _ : () } (
			glob("$v2/git/0.git/objects/*/*")));
	lei_ok(qw(import t/data/0001.patch));
	lei_ok 'up', $v2;
	lei_ok(qw(q z:0.. -o), "mboxrd:$home/after", '--only', $v2, '-j1,1');
	open $fh, '<', "$home/after";
	PublicInbox::MboxReader->mboxrd($fh, sub { push @after, $_[0] });

	my $last = shift @after;
	$last->header_set('Status');
	is_deeply($last, eml_load('t/data/0001.patch'), 'lei up worked on v2');
	is_deeply(\@before, \@after, 'got same results');

	my $v2s = "$home/v2s";
	lei_ok(qw(q --shared z:0.. -o), "v2:$v2s");
	my $shared = sum(map { -f $_ ? -s _ : () } (
			glob("$v2s/git/0.git/objects/*/*")));
	ok($shared < $orig, 'fewer bytes stored with --shared') or
		diag "shared=$shared orig=$orig";

	lei_ok([qw(edit-search), $v2s], { VISUAL => 'cat', EDITOR => 'cat' });
	like($lei_out, qr/^\[lei/sm, 'edit-search can cat');

	lei_ok('-C', "$home/v2s", qw(q -q -o ../s m:testmessage@example.com));
	lei_ok qw(ls-search);
	unlike $lei_out, qr{/\.\./s$}sm, 'relative path not in ls-search';
	like $lei_out, qr{^\Q$home\E/s$}sm,
		'absolute path appears in ls-search';
	lei_ok qw(up ../s -C), "$home/v2s", \'relative lei up';
	lei_ok qw(up), "$home/s", \'absolute lei up';

	# mess up a config file
	my @lss = glob("$home/" .
		'.local/share/lei/saved-searches/*/lei.saved-search');
	my $out = xqx([qw(git config -f), $lss[0], 'lei.q.output']);
	xsys($^X, qw(-i -p -e), "s/\\[/\\0/", $lss[0])
		and xbail "-ipe $lss[0]: $?";
	lei_ok qw(ls-search);
	like($lei_err, qr/bad config line.*?\Q$lss[0]\E/,
		'git config parse error shown w/ lei ls-search');
	lei_ok qw(up --all), \'up works with bad config';
	like($lei_err, qr/bad config line.*?\Q$lss[0]\E/,
		'git config parse error shown w/ lei up');
	xsys($^X, qw(-i -p -e), "s/\\0/\\[/", $lss[0])
		and xbail "-ipe $lss[0]: $?";
	lei_ok qw(ls-search);
	is($lei_err, '', 'no errors w/ fixed config');
});
done_testing;
