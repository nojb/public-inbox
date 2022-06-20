# Copyright (C) 2015-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::TestCommon;
require_mods(qw(DBD::SQLite Search::Xapian));
require PublicInbox::SearchIdx;
require PublicInbox::Inbox;
require PublicInbox::InboxWritable;
use PublicInbox::Eml;
use POSIX qw(strftime);
my ($tmpdir, $for_destroy) = tmpdir();
my $git_dir = "$tmpdir/a.git";
my $ibx = PublicInbox::Inbox->new({ inboxdir => $git_dir });
my ($root_id, $last_id);

is(0, xsys(qw(git init --shared -q --bare), $git_dir), "git init (main)")
	or BAIL_OUT("`git init --shared' failed, weird FS or seccomp?");
eval { PublicInbox::Search->new($ibx)->xdb };
ok($@, "exception raised on non-existent DB");

my $rw = PublicInbox::SearchIdx->new($ibx, 1);
$ibx->with_umask(sub {
	$rw->idx_acquire;
	$rw->idx_release;
});
$rw = undef;
my $rw_commit = sub {
	$rw->commit_txn_lazy if $rw;
	$rw = PublicInbox::SearchIdx->new($ibx, 1);
	$rw->{qp_flags} = 0; # quiet a warning
	$rw->begin_txn_lazy;
	$ibx->search->reopen;
};

sub oct_is ($$$) {
	my ($got, $exp, $msg) = @_;
	is(sprintf('0%03o', $got), sprintf('0%03o', $exp), $msg);
}

{
	# git repository perms
	oct_is($ibx->_git_config_perm(),
		&PublicInbox::InboxWritable::PERM_GROUP,
		'undefined permission is group');
	my @t = (
		[ '0644', 0022, '644 => umask(0022)' ],
		[ '0600', 0077, '600 => umask(0077)' ],
		[ '0640', 0027, '640 => umask(0027)' ],
		[ 'group', 0007, 'group => umask(0007)' ],
		[ 'everybody', 0002, 'everybody => umask(0002)' ],
		[ 'umask', umask, 'umask => existing umask' ],
	);
	for (@t) {
		my ($perm, $exp, $msg) = @$_;
		my $got = PublicInbox::InboxWritable::_umask_for(
			PublicInbox::InboxWritable->_git_config_perm($perm));
		oct_is($got, $exp, $msg);
	}
}

{
	my $crlf_adjust = \&PublicInbox::Smsg::crlf_adjust;
	is($crlf_adjust->("hi\r\nworld\r\n"), 0, 'no adjustment needed');
	is($crlf_adjust->("hi\nworld\n"), 2, 'LF-only counts two CR');
	is($crlf_adjust->("hi\r\nworld\n"), 1, 'CRLF/LF-mix 1 counts 1 CR');
	is($crlf_adjust->("hi\nworld\r\n"), 1, 'CRLF/LF-mix 2 counts 1 CR');
}

$ibx->with_umask(sub {
	my $root = PublicInbox::Eml->new(<<'EOF');
Date: Fri, 02 Oct 1993 00:00:00 +0000
Subject: Hello world
Message-ID: <root@s>
From: John Smith <js@example.com>
To: list@example.com
List-Id: I'm not mad <i.m.just.bored>

\m/
EOF
	my $last = PublicInbox::Eml->new(<<'EOF');
Date: Sat, 02 Oct 2010 00:00:00 +0000
Subject: Re: Hello world
In-Reply-To: <root@s>
Message-ID: <last@s>
From: John Smith <js@example.com>
To: list@example.com
Cc: foo@example.com
List-Id: there's nothing <left.for.me.to.do>

goodbye forever :<
EOF
	my $rv;
	$rw_commit->();
	$root_id = $rw->add_message($root);
	is($root_id, int($root_id), "root_id is an integer: $root_id");
	$last_id = $rw->add_message($last);
	is($last_id, int($last_id), "last_id is an integer: $last_id");
});

sub filter_mids {
	my ($msgs) = @_;
	sort(map { $_->{mid} } @$msgs);
}

my $query = sub {
	my ($query_string, $opt) = @_;
	my $mset = $ibx->search->mset($query_string, $opt);
	$ibx->search->mset_to_smsg($ibx, $mset);
};

{
	$rw_commit->();
	my $found = $query->('m:root@s');
	is(scalar(@$found), 1, "message found");
	is($found->[0]->{mid}, 'root@s', 'mid set correctly') if @$found;

	my ($res, @res);
	my @exp = sort qw(root@s last@s);

	$res = $query->('s:(Hello world)');
	@res = filter_mids($res);
	is_deeply(\@res, \@exp, 'got expected results for s:() match');

	$res = $query->('s:"Hello world"');
	@res = filter_mids($res);
	is_deeply(\@res, \@exp, 'got expected results for s:"" match');

	$res = $query->('s:"Hello world"', {limit => 1});
	is(scalar @$res, 1, "limit works");
	my $first = $res->[0];

	$res = $query->('s:"Hello world"', {offset => 1});
	is(scalar @$res, 1, "offset works");
	my $second = $res->[0];

	isnt($first, $second, "offset returned different result from limit");
}

# ghost vivication
$ibx->with_umask(sub {
	$rw_commit->();
	my $rmid = '<ghost-message@s>';
	my $reply_to_ghost = PublicInbox::Eml->new(<<"EOF");
Date: Sat, 02 Oct 2010 00:00:00 +0000
Subject: Re: ghosts
Message-ID: <ghost-reply\@s>
In-Reply-To: $rmid
From: Time Traveler <tt\@example.com>
To: list\@example.com

-_-
EOF
	my $rv;
	my $reply_id = $rw->add_message($reply_to_ghost);
	is($reply_id, int($reply_id), "reply_id is an integer: $reply_id");

	my $was_ghost = PublicInbox::Eml->new(<<"EOF");
Date: Sat, 02 Oct 2010 00:00:01 +0000
Subject: ghosts
Message-ID: $rmid
From: Laggy Sender <lag\@example.com>
To: list\@example.com

are real
EOF
	my $ghost_id = $rw->add_message($was_ghost);
	is($ghost_id, int($ghost_id), "ghost_id is an integer: $ghost_id");
	my $msgs = $rw->{oidx}->get_thread('ghost-message@s');
	is(scalar(@$msgs), 2, 'got both messages in ghost thread');
	foreach (qw(sid tid)) {
		is($msgs->[0]->{$_}, $msgs->[1]->{$_}, "{$_} match");
	}
	isnt($msgs->[0]->{num}, $msgs->[1]->{num}, "num do not match");
	ok($_->{num} > 0, 'positive art num') foreach @$msgs
});

# search thread on ghost
{
	$rw_commit->();

	# subject
	my $res = $query->('ghost');
	my @exp = sort qw(ghost-message@s ghost-reply@s);
	my @res = filter_mids($res);
	is_deeply(\@res, \@exp, 'got expected results for Subject match');

	# body
	$res = $query->('goodbye');
	is(scalar(@$res), 1, "goodbye message found");
	is($res->[0]->{mid}, 'last@s', 'got goodbye message body') if @$res;

	# datestamp
	$res = $query->('dt:20101002000001..20101002000001');
	@res = filter_mids($res);
	is_deeply(\@res, ['ghost-message@s'], 'exact Date: match works');
	$res = $query->('dt:20101002000002..20101002000002');
	is_deeply($res, [], 'exact Date: match down to the second');
}

# long message-id
$ibx->with_umask(sub {
	$rw_commit->();
	my $long_mid = 'last' . ('x' x 60). '@s';
	my $long = PublicInbox::Eml->new(<<EOF);
Date: Sat, 02 Oct 2010 00:00:00 +0000
Subject: long message ID
References: <root\@s> <last\@s>
In-Reply-To: <last\@s>
Message-ID: <$long_mid>,
From: "Long I.D." <long-id\@example.com>
To: list\@example.com

wut
EOF
	my $long_id = $rw->add_message($long);
	is($long_id, int($long_id), "long_id is an integer: $long_id");

	$rw_commit->();
	my $res;
	my @res;

	my $long_reply_mid = 'reply-to-long@1';
	my $long_reply = PublicInbox::Eml->new(<<EOF);
Subject: I break references
Date: Sat, 02 Oct 2010 00:00:00 +0000
Message-ID: <$long_reply_mid>
In-Reply-To: <$long_mid>
From: no1 <no1\@example.com>
To: list\@example.com

no References
EOF
	ok($rw->add_message($long_reply) > $long_id, "inserted long reply");

	$rw_commit->();
	my $t = $ibx->over->get_thread('root@s');
	is(scalar(@$t), 4, "got all 4 messages in thread");
	my @exp = sort($long_reply_mid, 'root@s', 'last@s', $long_mid);
	@res = filter_mids($t);
	is_deeply(\@res, \@exp, "get_thread works");
});

# quote prioritization
$ibx->with_umask(sub {
	$rw_commit->();
	$rw->add_message(PublicInbox::Eml->new(<<'EOF'));
Date: Sat, 02 Oct 2010 00:00:01 +0000
Subject: Hello
Message-ID: <quote@a>
From: Quoter <quoter@example.com>
To: list@example.com

> theatre illusions
fade
EOF
	$rw->add_message(PublicInbox::Eml->new(<<'EOF'));
Date: Sat, 02 Oct 2010 00:00:02 +0000
Subject: Hello
Message-ID: <nquote@a>
From: Non-Quoter<non-quoter@example.com>
To: list@example.com

theatre
fade
EOF
	$rw_commit->();
	my $res = $query->("theatre");
	is(scalar(@$res), 2, "got both matches");
	if (@$res == 2) {
		is($res->[0]->{mid}, 'nquote@a', 'non-quoted scores higher');
		is($res->[1]->{mid}, 'quote@a', 'quoted result still returned');
	}
	$res = $query->("illusions");
	is(scalar(@$res), 1, "got a match for quoted text");
	is($res->[0]->{mid}, 'quote@a',
		"quoted result returned if nothing else") if scalar(@$res);
});

# circular references
$ibx->with_umask(sub {
	my $s = 'foo://'. ('Circle' x 15).'/foo';
	my $doc_id = $rw->add_message(PublicInbox::Eml->new(<<EOF));
Subject: $s
Date: Sat, 02 Oct 2010 00:00:01 +0000
Message-ID: <circle\@a>
References: <circle\@a>
In-Reply-To: <circle\@a>
From: Circle <circle\@example.com>
To: list\@example.com

LOOP!
EOF
	ok($doc_id > 0, "doc_id defined with circular reference");
	$rw_commit->();
	my $smsg = $query->('m:circle@a', {limit=>1})->[0];
	is(defined($smsg), 1, 'found m:circl@a');
	if (defined $smsg) {
		is($smsg->{references}, '', "no references created");
		is($smsg->{subject}, $s, 'long subject not rewritten');
	}
});

{
	my $msgs = $query->('d:19931002..20101002');
	ok(scalar(@$msgs) > 0, 'got results within range');
	$msgs = $query->('d:20101003..');
	is(scalar(@$msgs), 0, 'nothing after 20101003');
	$msgs = $query->('d:..19931001');
	is(scalar(@$msgs), 0, 'nothing before 19931001');
}

$ibx->with_umask(sub {
	my $mime = eml_load 't/utf8.eml';
	my $doc_id = $rw->add_message($mime);
	ok($doc_id > 0, 'message indexed doc_id with UTF-8');
	$rw_commit->();
	my $msg = $query->('m:testmessage@example.com', {limit => 1})->[0];
	is(defined($msg), 1, 'found testmessage@example.com');
	if (defined $msg) {
		is($mime->header('Subject'), $msg->{subject},
			'UTF-8 subject preserved');
	}
});

# names and addresses
{
	my $mset = $ibx->search->mset('t:list@example.com');
	is($mset->size, 9, 'searched To: successfully');
	foreach my $m ($mset->items) {
		my $smsg = $ibx->over->get_art($m->get_docid);
		like($smsg->{to}, qr/\blist\@example\.com\b/, 'to appears');
		my $doc = $m->get_document;
		my $col = PublicInbox::Search::BYTES();
		my $bytes = PublicInbox::Search::int_val($doc, $col);
		like($bytes, qr/\A[0-9]+\z/, '$bytes stored as digit');
		ok($bytes > 0, '$bytes is > 0');
		is($bytes, $smsg->{bytes}, 'bytes Xapian value matches Over');

		$col = PublicInbox::Search::UID();
		my $uid = PublicInbox::Search::int_val($doc, $col);
		is($uid, $smsg->{num}, 'UID column matches {num}');
		is($uid, $m->get_docid, 'UID column matches docid');
	}

	$mset = $ibx->search->mset('tc:list@example.com');
	is($mset->size, 9, 'searched To+Cc: successfully');
	foreach my $m ($mset->items) {
		my $smsg = $ibx->over->get_art($m->get_docid);
		my $tocc = join("\n", $smsg->{to}, $smsg->{cc});
		like($tocc, qr/\blist\@example\.com\b/, 'tocc appears');
	}

	foreach my $pfx ('tcf:', 'c:') {
		my $mset = $ibx->search->mset($pfx . 'foo@example.com');
		is($mset->items, 1, "searched $pfx successfully for Cc:");
		foreach my $m ($mset->items) {
			my $smsg = $ibx->over->get_art($m->get_docid);
			like($smsg->{cc}, qr/\bfoo\@example\.com\b/,
				'cc appears');
		}
	}

	foreach my $pfx ('', 'tcf:', 'f:') {
		my $res = $query->($pfx . 'Laggy');
		is(scalar(@$res), 1,
			"searched $pfx successfully for From:");
		foreach my $smsg (@$res) {
			like($smsg->{from_name}, qr/Laggy Sender/,
				"From appears with $pfx");
		}
	}
}

{
	$rw_commit->();
	my $res = $query->('b:hello');
	is(scalar(@$res), 0, 'no match on body search only');
	$res = $query->('bs:smith');
	is(scalar(@$res), 0,
		'no match on body+subject search for From');

	$res = $query->('q:theatre');
	is(scalar(@$res), 1, 'only one quoted body');
	like($res->[0]->{from_name}, qr/\AQuoter/,
		'got quoted body') if (scalar(@$res));

	$res = $query->('nq:theatre');
	is(scalar @$res, 1, 'only one non-quoted body');
	like($res->[0]->{from_name}, qr/\ANon-Quoter/,
		'got non-quoted body') if (scalar(@$res));

	foreach my $pfx (qw(b: bs:)) {
		$res = $query->($pfx . 'theatre');
		is(scalar @$res, 2, "searched both bodies for $pfx");
		like($res->[0]->{from_name}, qr/\ANon-Quoter/,
			"non-quoter first for $pfx") if scalar(@$res);
	}
}

$ibx->with_umask(sub {
	my $amsg = eml_load 't/search-amsg.eml';
	my $oid = ('0'x40);
	my $smsg = bless { blob => $oid }, 'PublicInbox::Smsg';
	ok($rw->add_message($amsg, $smsg), 'added attachment');
	$rw_commit->();
	my $n = $query->('n:attached_fart.txt');
	is(scalar @$n, 1, 'got result for n:');
	my $res = $query->('part_deux.txt');
	is(scalar @$res, 1, 'got result without n:');
	is($n->[0]->{mid}, $res->[0]->{mid},
		'same result with and without') if scalar(@$res);
	my $txt = $query->('"inside another"');
	is(scalar @$txt, 1, 'found inside another');
	is($txt->[0]->{mid}, $res->[0]->{mid},
		'search inside text attachments works') if scalar(@$txt);

	my $art;
	if (scalar(@$n) >= 1) {
		my $mid = $n->[0]->{mid};
		my ($id, $prev);
		$art = $ibx->over->next_by_mid($mid, \$id, \$prev);
		ok($art, 'article exists in OVER DB');
	}
	$rw->_msgmap_init;
	$rw->unindex_eml($oid, $amsg);
	$rw->commit_txn_lazy;
	SKIP: {
		skip('$art not defined', 1) unless defined $art;
		is($ibx->over->get_art($art->{num}), undef,
			'gone from OVER DB');
	};
});

my $all_mask = 07777;
my $dir_mask = 02770;

# FreeBSD and apparently OpenBSD does not allow non-root users to set S_ISGID,
# so git doesn't set it, either (see DIR_HAS_BSD_GROUP_SEMANTICS in git.git)
if ($^O =~ /(?:free|open)bsd/i) {
	$all_mask = 0777;
	$dir_mask = 0770;
}

foreach my $f ("$git_dir/public-inbox/msgmap.sqlite3",
		"$git_dir/public-inbox",
		glob("$git_dir/public-inbox/xapian*/"),
		glob("$git_dir/public-inbox/xapian*/*")) {
	my @st = stat($f);
	my ($bn) = (split(m!/!, $f))[-1];
	oct_is($st[2] & $all_mask, -f _ ? 0660 : $dir_mask,
		"sharedRepository respected for $bn");
}

$ibx->with_umask(sub {
	$rw_commit->();
	my $digits = '10010260936330';
	my $ua = 'Pine.LNX.4.10';
	my $mid = "$ua.$digits.2460-100000\@penguin.transmeta.com";
	is($ibx->search->mset("m:$digits")->size, 0, 'no results yet');
	my $pine = PublicInbox::Eml->new(<<EOF);
Subject: blah
Message-ID: <$mid>
From: torvalds\@transmeta
To: list\@example.com

EOF
	my $x = $rw->add_message($pine);
	$rw->commit_txn_lazy;
	$ibx->search->reopen;
	is($ibx->search->mset("m:$digits")->size, 1,
		'searching only digit yielded result');

	my $wild = $digits;
	for my $i (1..6) {
		chop($wild);
		is($ibx->search->mset("m:$wild*")->size, 1,
			"searching chopped($i) digit yielded result $wild ");
	}
	is($ibx->search->mset('m:Pine m:LNX m:10010260936330')->size, 1);
});

{ # List-Id searching
	my $found = $query->('lid:i.m.just.bored');
	is_deeply([ filter_mids($found) ], [ 'root@s' ],
		'got expected mid on exact lid: search');

	$found = $query->('lid:just.bored');
	is_deeply($found, [], 'got nothing on lid: search');

	$found = $query->('lid:*.just.bored');
	is_deeply($found, [], 'got nothing on lid: search');

	$found = $query->('l:i.m.just.bored');
	is_deeply([ filter_mids($found) ], [ 'root@s' ],
		'probabilistic search works on full List-Id contents');

	$found = $query->('l:just.bored');
	is_deeply([ filter_mids($found) ], [ 'root@s' ],
		'probabilistic search works on partial List-Id contents');

	$found = $query->('lid:mad');
	is_deeply($found, [], 'no match on phrase with lid:');

	$found = $query->('lid:bored');
	is_deeply($found, [], 'no match on partial List-Id with lid:');

	$found = $query->('l:nothing');
	is_deeply($found, [], 'matched on phrase with l:');
}

$ibx->with_umask(sub {
	$rw_commit->();
	my $doc_id = $rw->add_message(eml_load('t/data/message_embed.eml'));
	ok($doc_id > 0, 'messages within messages');
	$rw->commit_txn_lazy;
	$ibx->search->reopen;
	my $n_test_eml = $query->('n:test.eml');
	is(scalar(@$n_test_eml), 1, 'got a result');
	my $n_embed2x_eml = $query->('n:embed2x.eml');
	is_deeply($n_test_eml, $n_embed2x_eml, '.eml filenames searchable');
	for my $m (qw(20200418222508.GA13918@dcvr 20200418222020.GA2745@dcvr
			20200418214114.7575-1-e@yhbt.net)) {
		is($query->("m:$m")->[0]->{mid},
			'20200418222508.GA13918@dcvr', 'probabilistic m:'.$m);
		is($query->("mid:$m")->[0]->{mid},
			'20200418222508.GA13918@dcvr', 'boolean mid:'.$m);
	}
	is($query->('dfpost:4dc62c50')->[0]->{mid},
		'20200418222508.GA13918@dcvr',
		'diff search reaches inside message/rfc822');
	is($query->('s:"mail header experiments"')->[0]->{mid},
		'20200418222508.GA13918@dcvr',
		'Subject search reaches inside message/rfc822');

	$doc_id = $rw->add_message(eml_load('t/data/binary.patch'));
	$rw->commit_txn_lazy;
	$ibx->search->reopen;
	my $res = $query->('HcmV');
	is_deeply($res, [], 'no results against trailer');
	$res = $query->('IcmZPo000310RR91');
	is_deeply($res, [], 'no results against 1-byte binary patch');
	$res = $query->('"GIT binary patch"');
	is(scalar(@$res), 1, 'got binary result from "GIT binary patch"');
	is($res->[0]->{mid}, 'binary-patch-test@example', 'msgid for binary');
	my $s = $query->('"literal 1"');
	is_deeply($s, $res, 'got binary result from exact literal size');
	$s = $query->('"literal 2"');
	is_deeply($s, [], 'no results for wrong size');
});

SKIP: {
	my ($s, $g) = ($ibx->search, $ibx->git);
	my $q = $s->query_argv_to_string($g, ["quoted phrase"]);
	is($q, q["quoted phrase"], 'quoted phrase');
	$q = $s->query_argv_to_string($g, ['s:pa ce']);
	is($q, q[s:"pa ce"], 'space with prefix');
	$q = $s->query_argv_to_string($g, ["\(s:pa ce", "AND", "foo\)"]);
	is($q, q[(s:"pa ce" AND foo)], 'space AND foo');

	local $ENV{TZ} = 'UTC';
	my $now = strftime('%H:%M:%S', gmtime(time));
	if ($now =~ /\A23:(?:59|60)/ || $now =~ /\A00:00:0[01]\z/) {
		skip 'too close to midnight, time is tricky', 6;
	}
	$q = $s->query_argv_to_string($g, [qw(d:20101002 blah)]);
	is($q, 'd:20101002..20101003 blah', 'YYYYMMDD expanded to range');
	$q = $s->query_argv_to_string($g, [qw(d:2010-10-02)]);
	is($q, 'd:20101002..20101003', 'YYYY-MM-DD expanded to range');
	$q = $s->query_argv_to_string($g, [qw(rt:2010-10-02.. yy)]);
	$q =~ /\Art:(\d+)\.\. yy/ or fail("rt: expansion failed: $q");
	is(strftime('%Y-%m-%d', gmtime($1//0)), '2010-10-02', 'rt: beg expand');
	$q = $s->query_argv_to_string($g, [qw(rt:..2010-10-02 zz)]);
	$q =~ /\Art:\.\.(\d+) zz/ or fail("rt: expansion failed: $q");
	is(strftime('%Y-%m-%d', gmtime($1//0)), '2010-10-02', 'rt: end expand');
	$q = $s->query_argv_to_string($g, [qw(something dt:2010-10-02..)]);
	like($q, qr/\Asomething dt:20101002\d{6}\.\./, 'dt: expansion');
	$q = $s->query_argv_to_string($g, [qw(x dt:yesterday.. y)]);
	my $exp = strftime('%Y%m%d', gmtime(time - 86400));
	like($q, qr/x dt:$exp[0-9]{6}\.\. y/, '"yesterday" handled');
	$q = $s->query_argv_to_string($g, [qw(x dt:20101002054123)]);
	is($q, 'x dt:20101002054123..20101003054123', 'single dt: expanded');
	$q = $s->query_argv_to_string($g, [qw(x dt:2010-10-02T05:41:23Z)]);
	is($q, 'x dt:20101002054123..20101003054123', 'ISO8601 dt: expanded');
	$q = $s->query_argv_to_string($g, [qw(rt:1970..1971)]);
	$q =~ /\Art:(\d+)\.\.(\d+)\z/ or fail "YYYY rt: expansion: $q";
	my ($beg, $end) = ($1, $2);
	is(strftime('%Y', gmtime($beg)), 1970, 'rt: starts at 1970');
	is(strftime('%Y', gmtime($end)), 1971, 'rt: ends at 1971');
	$q = $s->query_argv_to_string($g, [qw(rt:1970-01-01)]);
	$q =~ /\Art:(\d+)\.\.(\d+)\z/ or fail "YYYY-MM-DD rt: expansion: $q";
	($beg, $end) = ($1, $2);
	is(strftime('%Y-%m-%d', gmtime($beg)), '1970-01-01',
			'rt: date-only w/o range');
	is(strftime('%Y-%m-%d', gmtime($end)), '1970-01-02',
			'rt: date-only auto-end');
	$q = $s->query_argv_to_string($g, [qw{OR (rt:1993-10-02)}]);
	like($q, qr/\AOR \(rt:749\d{6}\.\.749\d{6}\)\z/,
		'trailing parentheses preserved');

	my $qs = qq[f:bob rt:1993-10-02..2010-10-02];
	$s->query_approxidate($g, $qs);
	like($qs, qr/\Af:bob rt:749\d{6}\.\.128\d{7}\z/,
		'no phrases, no problem');

	my $orig = $qs = qq[f:bob "d:1993-10-02..2010-10-02"];
	$s->query_approxidate($g, $qs);
	is($qs, $orig, 'phrase preserved');

	$orig = $qs = qq[f:bob "d:1993-10-02..2010-10-02 "] .
			qq["dt:1993-10-02..2010-10-02 " \x{201c}];
	$s->query_approxidate($g, $qs);
	is($qs, $orig, 'phrase preserved even with escaped ""');

	$orig = $qs = qq[f:bob "hello world" d:1993-10-02..2010-10-02];
	$s->query_approxidate($g, $qs);
	is($qs, qq[f:bob "hello world" d:19931002..20101002],
		'post-phrase date corrected');

	# Xapian uses "" to escape " inside phrases, we don't explictly
	# handle that, but are able to pass the result through unchanged
	for my $pair (["\x{201c}", "\x{201d}"], ['"', '"']) {
		my ($x, $y) = @$pair;
		$orig = $qs = qq[${x}hello d:1993-10-02.."" world$y];
		$s->query_approxidate($g, $qs);
		is($qs, $orig, 'phrases unchanged \x'.ord($x).'-\x'.ord($y));

		$s->query_approxidate($g, my $tmp = "$qs d:..2010-10-02");
		is($tmp, "$orig d:..20101002",
			'two phrases did not throw off date parsing');

		$orig = $qs = qq[${x}hello d:1993-10-02..$y$x world$y];
		$s->query_approxidate($g, $qs);
		is($qs, $orig, 'phrases unchanged \x'.ord($x).'-\x'.ord($y));

		$s->query_approxidate($g, $tmp = "$qs d:..2010-10-02");
		is($tmp, "$orig d:..20101002",
			'two phrases did not throw off date parsing');
	}

	my $x_days_ago = strftime('%Y%m%d', gmtime(time - (5 * 86400)));
	$orig = $qs = qq[broken d:5.days.ago..];
	$s->query_approxidate($g, $qs);
	like($qs, qr/\Abroken dt:$x_days_ago[0-9]{6}\.\./,
		'date.phrase.with.dots');

	$orig = $qs = 'd:20101002..now';
	$s->query_approxidate($g, $qs);
	like($qs, qr/\Adt:20101002000000\.\.[0-9]{14}\z/,
		'approxidate on range-end only');

	$ENV{TEST_EXPENSIVE} or
		skip 'TEST_EXPENSIVE not set for argv overflow check', 1;
	my @w;
	local $SIG{__WARN__} = sub { push @w, @_ }; # for pure Perl version
	my @fail = map { 'd:1993-10-02..2010-10-02' } (1..(4096 * 32));
	eval { $s->query_argv_to_string($g, \@fail) };
	ok($@, 'exception raised');
}

done_testing();
