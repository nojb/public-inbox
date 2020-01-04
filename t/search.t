# Copyright (C) 2015-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::TestCommon;
require_mods(qw(DBD::SQLite Search::Xapian));
require PublicInbox::SearchIdx;
require PublicInbox::Inbox;
use Email::MIME;
my ($tmpdir, $for_destroy) = tmpdir();
my $git_dir = "$tmpdir/a.git";
my $ibx = PublicInbox::Inbox->new({ inboxdir => $git_dir });
my ($root_id, $last_id);

is(0, system(qw(git init --shared -q --bare), $git_dir), "git init (main)")
	or BAIL_OUT("`git init --shared' failed, weird FS or seccomp?");
eval { PublicInbox::Search->new($ibx)->xdb };
ok($@, "exception raised on non-existent DB");

my $rw = PublicInbox::SearchIdx->new($ibx, 1);
$ibx->with_umask(sub {
	$rw->_xdb_acquire;
	$rw->_xdb_release;
});
$rw = undef;
my $ro = PublicInbox::Search->new($ibx);
my $rw_commit = sub {
	$rw->commit_txn_lazy if $rw;
	$rw = PublicInbox::SearchIdx->new($ibx, 1);
	$rw->{qp_flags} = 0; # quiet a warning
	$rw->begin_txn_lazy;
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

$ibx->with_umask(sub {
	my $root = Email::MIME->create(
		header_str => [
			Date => 'Fri, 02 Oct 1993 00:00:00 +0000',
			Subject => 'Hello world',
			'Message-ID' => '<root@s>',
			From => 'John Smith <js@example.com>',
			To => 'list@example.com',
		],
		body => "\\m/\n");
	my $last = Email::MIME->create(
		header_str => [
			Date => 'Sat, 02 Oct 2010 00:00:00 +0000',
			Subject => 'Re: Hello world',
			'In-Reply-To' => '<root@s>',
			'Message-ID' => '<last@s>',
			From => 'John Smith <js@example.com>',
			To => 'list@example.com',
			Cc => 'foo@example.com',
		],
		body => "goodbye forever :<\n");

	my $rv;
	$rw_commit->();
	$root_id = $rw->add_message($root);
	is($root_id, int($root_id), "root_id is an integer: $root_id");
	$last_id = $rw->add_message($last);
	is($last_id, int($last_id), "last_id is an integer: $last_id");
});

sub filter_mids {
	my ($msgs) = @_;
	sort(map { $_->mid } @$msgs);
}

{
	$rw_commit->();
	$ro->reopen;
	my $found = $ro->query('m:root@s');
	is(scalar(@$found), 1, "message found");
	is($found->[0]->mid, 'root@s', 'mid set correctly') if scalar(@$found);

	my ($res, @res);
	my @exp = sort qw(root@s last@s);

	$res = $ro->query('s:(Hello world)');
	@res = filter_mids($res);
	is_deeply(\@res, \@exp, 'got expected results for s:() match');

	$res = $ro->query('s:"Hello world"');
	@res = filter_mids($res);
	is_deeply(\@res, \@exp, 'got expected results for s:"" match');

	$res = $ro->query('s:"Hello world"', {limit => 1});
	is(scalar @$res, 1, "limit works");
	my $first = $res->[0];

	$res = $ro->query('s:"Hello world"', {offset => 1});
	is(scalar @$res, 1, "offset works");
	my $second = $res->[0];

	isnt($first, $second, "offset returned different result from limit");
}

# ghost vivication
$ibx->with_umask(sub {
	$rw_commit->();
	my $rmid = '<ghost-message@s>';
	my $reply_to_ghost = Email::MIME->create(
		header_str => [
			Date => 'Sat, 02 Oct 2010 00:00:00 +0000',
			Subject => 'Re: ghosts',
			'Message-ID' => '<ghost-reply@s>',
			'In-Reply-To' => $rmid,
			From => 'Time Traveler <tt@example.com>',
			To => 'list@example.com',
		],
		body => "-_-\n");

	my $rv;
	my $reply_id = $rw->add_message($reply_to_ghost);
	is($reply_id, int($reply_id), "reply_id is an integer: $reply_id");

	my $was_ghost = Email::MIME->create(
		header_str => [
			Date => 'Sat, 02 Oct 2010 00:00:01 +0000',
			Subject => 'ghosts',
			'Message-ID' => $rmid,
			From => 'Laggy Sender <lag@example.com>',
			To => 'list@example.com',
		],
		body => "are real\n");

	my $ghost_id = $rw->add_message($was_ghost);
	is($ghost_id, int($ghost_id), "ghost_id is an integer: $ghost_id");
	my $msgs = $rw->{over}->get_thread('ghost-message@s');
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
	$ro->reopen;

	# subject
	my $res = $ro->query('ghost');
	my @exp = sort qw(ghost-message@s ghost-reply@s);
	my @res = filter_mids($res);
	is_deeply(\@res, \@exp, 'got expected results for Subject match');

	# body
	$res = $ro->query('goodbye');
	is(scalar(@$res), 1, "goodbye message found");
	is($res->[0]->mid, 'last@s', 'got goodbye message body') if scalar(@$res);

	# datestamp
	$res = $ro->query('dt:20101002000001..20101002000001');
	@res = filter_mids($res);
	is_deeply(\@res, ['ghost-message@s'], 'exact Date: match works');
	$res = $ro->query('dt:20101002000002..20101002000002');
	is_deeply($res, [], 'exact Date: match down to the second');
}

# long message-id
$ibx->with_umask(sub {
	$rw_commit->();
	$ro->reopen;
	my $long_mid = 'last' . ('x' x 60). '@s';

	my $long = Email::MIME->create(
		header_str => [
			Date => 'Sat, 02 Oct 2010 00:00:00 +0000',
			Subject => 'long message ID',
			'References' => '<root@s> <last@s>',
			'In-Reply-To' => '<last@s>',
			'Message-ID' => "<$long_mid>",
			From => '"Long I.D." <long-id@example.com>',
			To => 'list@example.com',
		],
		body => "wut\n");
	my $long_id = $rw->add_message($long);
	is($long_id, int($long_id), "long_id is an integer: $long_id");

	$rw_commit->();
	$ro->reopen;
	my $res;
	my @res;

	my $long_reply_mid = 'reply-to-long@1';
	my $long_reply = Email::MIME->create(
		header_str => [
			Subject => 'I break references',
			Date => 'Sat, 02 Oct 2010 00:00:00 +0000',
			'Message-ID' => "<$long_reply_mid>",
			# No References:
			# 'References' => '<root@s> <last@s> <'.$long_mid.'>',
			'In-Reply-To' => "<$long_mid>",
			From => 'no1 <no1@example.com>',
			To => 'list@example.com',
		],
		body => "no References\n");
	ok($rw->add_message($long_reply) > $long_id, "inserted long reply");

	$rw_commit->();
	$ro->reopen;
	my $t = $ro->{over_ro}->get_thread('root@s');
	is(scalar(@$t), 4, "got all 4 mesages in thread");
	my @exp = sort($long_reply_mid, 'root@s', 'last@s', $long_mid);
	@res = filter_mids($t);
	is_deeply(\@res, \@exp, "get_thread works");
});

# quote prioritization
$ibx->with_umask(sub {
	$rw_commit->();
	$rw->add_message(Email::MIME->create(
		header_str => [
			Date => 'Sat, 02 Oct 2010 00:00:01 +0000',
			Subject => 'Hello',
			'Message-ID' => '<quote@a>',
			From => 'Quoter <quoter@example.com>',
			To => 'list@example.com',
		],
		body => "> theatre illusions\nfade\n"));

	$rw->add_message(Email::MIME->create(
		header_str => [
			Date => 'Sat, 02 Oct 2010 00:00:02 +0000',
			Subject => 'Hello',
			'Message-ID' => '<nquote@a>',
			From => 'Non-Quoter<non-quoter@example.com>',
			To => 'list@example.com',
		],
		body => "theatre\nfade\n"));
	my $res = $rw->query("theatre");
	is(scalar(@$res), 2, "got both matches");
	is($res->[0]->mid, 'nquote@a', "non-quoted scores higher") if scalar(@$res);
	is($res->[1]->mid, 'quote@a', "quoted result still returned") if scalar(@$res);

	$res = $rw->query("illusions");
	is(scalar(@$res), 1, "got a match for quoted text");
	is($res->[0]->mid, 'quote@a',
		"quoted result returned if nothing else") if scalar(@$res);
});

# circular references
$ibx->with_umask(sub {
	my $s = 'foo://'. ('Circle' x 15).'/foo';
	my $doc_id = $rw->add_message(Email::MIME->create(
		header => [ Subject => $s ],
		header_str => [
			Date => 'Sat, 02 Oct 2010 00:00:01 +0000',
			'Message-ID' => '<circle@a>',
			'References' => '<circle@a>',
			'In-Reply-To' => '<circle@a>',
			From => 'Circle <circle@example.com>',
			To => 'list@example.com',
		],
		body => "LOOP!\n"));
	ok($doc_id > 0, "doc_id defined with circular reference");
	my $smsg = $rw->query('m:circle@a', {limit=>1})->[0];
	is(defined($smsg), 1, 'found m:circl@a');
	is($smsg->references, '', "no references created") if defined($smsg);
	is($smsg->subject, $s, 'long subject not rewritten') if defined($smsg);
});

$ibx->with_umask(sub {
	my $str = eval {
		my $mbox = 't/utf8.mbox';
		open(my $fh, '<', $mbox) or die "failed to open mbox: $mbox\n";
		local $/;
		<$fh>
	};
	$str =~ s/\AFrom [^\n]+\n//s;
	my $mime = Email::MIME->new($str);
	my $doc_id = $rw->add_message($mime);
	ok($doc_id > 0, 'message indexed doc_id with UTF-8');
	my $msg = $rw->query('m:testmessage@example.com', {limit => 1})->[0];
	is(defined($msg), 1, 'found testmessage@example.com');
	is($mime->header('Subject'), $msg->subject, 'UTF-8 subject preserved') if defined($msg);
});

{
	my $msgs = $ro->query('d:19931002..20101002');
	ok(scalar(@$msgs) > 0, 'got results within range');
	$msgs = $ro->query('d:20101003..');
	is(scalar(@$msgs), 0, 'nothing after 20101003');
	$msgs = $ro->query('d:..19931001');
	is(scalar(@$msgs), 0, 'nothing before 19931001');
}

# names and addresses
{
	my $mset = $ro->query('t:list@example.com', {mset => 1});
	is($mset->size, 6, 'searched To: successfully');
	foreach my $m ($mset->items) {
		my $smsg = $ro->{over_ro}->get_art($m->get_docid);
		like($smsg->to, qr/\blist\@example\.com\b/, 'to appears');
	}

	$mset = $ro->query('tc:list@example.com', {mset => 1});
	is($mset->size, 6, 'searched To+Cc: successfully');
	foreach my $m ($mset->items) {
		my $smsg = $ro->{over_ro}->get_art($m->get_docid);
		my $tocc = join("\n", $smsg->to, $smsg->cc);
		like($tocc, qr/\blist\@example\.com\b/, 'tocc appears');
	}

	foreach my $pfx ('tcf:', 'c:') {
		my $mset = $ro->query($pfx . 'foo@example.com', { mset => 1 });
		is($mset->items, 1, "searched $pfx successfully for Cc:");
		foreach my $m ($mset->items) {
			my $smsg = $ro->{over_ro}->get_art($m->get_docid);
			like($smsg->cc, qr/\bfoo\@example\.com\b/,
				'cc appears');
		}
	}

	foreach my $pfx ('', 'tcf:', 'f:') {
		my $res = $ro->query($pfx . 'Laggy');
		is(scalar(@$res), 1,
			"searched $pfx successfully for From:");
		foreach my $smsg (@$res) {
			like($smsg->from_name, qr/Laggy Sender/,
				"From appears with $pfx");
		}
	}
}

{
	$rw_commit->();
	$ro->reopen;
	my $res = $ro->query('b:hello');
	is(scalar(@$res), 0, 'no match on body search only');
	$res = $ro->query('bs:smith');
	is(scalar(@$res), 0,
		'no match on body+subject search for From');

	$res = $ro->query('q:theatre');
	is(scalar(@$res), 1, 'only one quoted body');
	like($res->[0]->from_name, qr/\AQuoter/,
		'got quoted body') if (scalar(@$res));

	$res = $ro->query('nq:theatre');
	is(scalar @$res, 1, 'only one non-quoted body');
	like($res->[0]->from_name, qr/\ANon-Quoter/,
		'got non-quoted body') if (scalar(@$res));

	foreach my $pfx (qw(b: bs:)) {
		$res = $ro->query($pfx . 'theatre');
		is(scalar @$res, 2, "searched both bodies for $pfx");
		like($res->[0]->from_name, qr/\ANon-Quoter/,
			"non-quoter first for $pfx") if scalar(@$res);
	}
}

$ibx->with_umask(sub {
	my $part1 = Email::MIME->create(
                 attributes => {
                     content_type => 'text/plain',
                     disposition  => 'attachment',
                     charset => 'US-ASCII',
		     encoding => 'quoted-printable',
		     filename => 'attached_fart.txt',
                 },
                 body_str => 'inside the attachment',
	);
	my $part2 = Email::MIME->create(
                 attributes => {
                     content_type => 'text/plain',
                     disposition  => 'attachment',
                     charset => 'US-ASCII',
		     encoding => 'quoted-printable',
		     filename => 'part_deux.txt',
                 },
                 body_str => 'inside another',
	);
	my $amsg = Email::MIME->create(
		header_str => [
			Subject => 'see attachment',
			'Message-ID' => '<file@attached>',
			From => 'John Smith <js@example.com>',
			To => 'list@example.com',
		],
		parts => [ $part1, $part2 ],
	);
	ok($rw->add_message($amsg), 'added attachment');
	$rw_commit->();
	$ro->reopen;
	my $n = $ro->query('n:attached_fart.txt');
	is(scalar @$n, 1, 'got result for n:');
	my $res = $ro->query('part_deux.txt');
	is(scalar @$res, 1, 'got result without n:');
	is($n->[0]->mid, $res->[0]->mid,
		'same result with and without') if scalar(@$res);
	my $txt = $ro->query('"inside another"');
	is(scalar @$txt, 1, 'found inside another');
	is($txt->[0]->mid, $res->[0]->mid,
		'search inside text attachments works') if scalar(@$txt);

	my $art;
	if (scalar(@$n) >= 1) {
		my $mid = $n->[0]->mid;
		my ($id, $prev);
		$art = $ro->{over_ro}->next_by_mid($mid, \$id, \$prev);
		ok($art, 'article exists in OVER DB');
	}
	$rw->unindex_blob($amsg);
	$rw->commit_txn_lazy;
	SKIP: {
		skip('$art not defined', 1) unless defined $art;
		is($ro->{over_ro}->get_art($art->{num}), undef,
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
	is($ro->reopen->query("m:$digits", { mset => 1})->size, 0,
		'no results yet');
	my $pine = Email::MIME->create(
		header_str => [
			Subject => 'blah',
			'Message-ID' => "<$mid>",
			From => 'torvalds@transmeta',
			To => 'list@example.com',
		],
		body => ""
	);
	my $x = $rw->add_message($pine);
	$rw->commit_txn_lazy;
	is($ro->reopen->query("m:$digits", { mset => 1})->size, 1,
		'searching only digit yielded result');

	my $wild = $digits;
	for my $i (1..6) {
		chop($wild);
		is($ro->query("m:$wild*", { mset => 1})->size, 1,
			"searching chopped($i) digit yielded result $wild ");
	}
	is($ro->query("m:Pine m:LNX m:10010260936330", {mset=>1})->size, 1);
});

done_testing();

1;
