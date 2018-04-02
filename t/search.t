# Copyright (C) 2015-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
eval { require PublicInbox::SearchIdx; };
plan skip_all => "Xapian missing for search" if $@;
use File::Temp qw/tempdir/;
use Email::MIME;
my $tmpdir = tempdir('pi-search-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $git_dir = "$tmpdir/a.git";
my ($root_id, $last_id);

is(0, system(qw(git init -q --bare), $git_dir), "git init (main)");
eval { PublicInbox::Search->new($git_dir) };
ok($@, "exception raised on non-existent DB");

my $rw = PublicInbox::SearchIdx->new($git_dir, 1);
$rw->_xdb_acquire;
$rw->_xdb_release;
my $ibx = $rw->{-inbox};
$rw = undef;
my $ro = PublicInbox::Search->new($git_dir);
my $rw_commit = sub {
	$rw->commit_txn_lazy if $rw;
	$rw = PublicInbox::SearchIdx->new($git_dir, 1);
	$rw->begin_txn_lazy;
};

{
	# git repository perms
	is($ibx->_git_config_perm(), &PublicInbox::InboxWritable::PERM_GROUP,
	   "undefined permission is group");
	is(PublicInbox::InboxWritable::_umask_for(
	     PublicInbox::InboxWritable->_git_config_perm('0644')),
	   0022, "644 => umask(0022)");
	is(PublicInbox::InboxWritable::_umask_for(
	     PublicInbox::InboxWritable->_git_config_perm('0600')),
	   0077, "600 => umask(0077)");
	is(PublicInbox::InboxWritable::_umask_for(
	     PublicInbox::InboxWritable->_git_config_perm('0640')),
	   0027, "640 => umask(0027)");
	is(PublicInbox::InboxWritable::_umask_for(
	     PublicInbox::InboxWritable->_git_config_perm('group')),
	   0007, 'group => umask(0007)');
	is(PublicInbox::InboxWritable::_umask_for(
	     PublicInbox::InboxWritable->_git_config_perm('everybody')),
	   0002, 'everybody => umask(0002)');
	is(PublicInbox::InboxWritable::_umask_for(
	     PublicInbox::InboxWritable->_git_config_perm('umask')),
	   umask, 'umask => existing umask');
}

{
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
}

sub filter_mids {
	my ($res) = @_;
	sort(map { $_->mid } @{$res->{msgs}});
}

{
	$rw_commit->();
	$ro->reopen;
	my $found = $ro->first_smsg_by_mid('root@s');
	ok($found, "message found");
	is($root_id, $found->{doc_id}, 'doc_id set correctly');
	is($found->mid, 'root@s', 'mid set correctly');

	my ($res, @res);
	my @exp = sort qw(root@s last@s);

	$res = $ro->query('s:(Hello world)');
	@res = filter_mids($res);
	is_deeply(\@res, \@exp, 'got expected results for s:() match');

	$res = $ro->query('s:"Hello world"');
	@res = filter_mids($res);
	is_deeply(\@res, \@exp, 'got expected results for s:"" match');

	$res = $ro->query('s:"Hello world"', {limit => 1});
	is(scalar @{$res->{msgs}}, 1, "limit works");
	my $first = $res->{msgs}->[0];

	$res = $ro->query('s:"Hello world"', {offset => 1});
	is(scalar @{$res->{msgs}}, 1, "offset works");
	my $second = $res->{msgs}->[0];

	isnt($first, $second, "offset returned different result from limit");
}

# ghost vivication
{
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
	my $msgs = $rw->{over}->get_thread('ghost-message@s')->{msgs};
	is(scalar(@$msgs), 2, 'got both messages in ghost thread');
	foreach (qw(sid tid)) {
		is($msgs->[0]->{$_}, $msgs->[1]->{$_}, "{$_} match");
	}
	isnt($msgs->[0]->{num}, $msgs->[1]->{num}, "num do not match");
	ok($_->{num} > 0, 'positive art num') foreach @$msgs
}

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
	is($res->{msgs}->[0]->mid, 'last@s', 'got goodbye message body');
}

# long message-id
{
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
			From => '"no1 <no1@example.com>',
			To => 'list@example.com',
		],
		body => "no References\n");
	ok($rw->add_message($long_reply) > $long_id, "inserted long reply");

	$rw_commit->();
	$ro->reopen;
	my $t = $ro->get_thread('root@s');
	is($t->{total}, 4, "got all 4 mesages in thread");
	my @exp = sort($long_reply_mid, 'root@s', 'last@s', $long_mid);
	@res = filter_mids($t);
	is_deeply(\@res, \@exp, "get_thread works");
}

# quote prioritization
{
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
	is($res->{total}, 2, "got both matches");
	is($res->{msgs}->[0]->mid, 'nquote@a', "non-quoted scores higher");
	is($res->{msgs}->[1]->mid, 'quote@a', "quoted result still returned");

	$res = $rw->query("illusions");
	is($res->{total}, 1, "got a match for quoted text");
	is($res->{msgs}->[0]->mid, 'quote@a',
		"quoted result returned if nothing else");
}

# circular references
{
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
	my $smsg = $rw->first_smsg_by_mid('circle@a');
	is($smsg->references, '', "no references created");
	my $msg = PublicInbox::SearchMsg->load_doc($smsg->{doc});
	is($s, $msg->subject, 'long subject not rewritten');
}

{
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
	my $smsg = $rw->first_smsg_by_mid('testmessage@example.com');
	my $msg = PublicInbox::SearchMsg->load_doc($smsg->{doc});

	is($mime->header('Subject'), $msg->subject, 'UTF-8 subject preserved');
}

{
	my $res = $ro->query('d:19931002..20101002');
	ok(scalar @{$res->{msgs}} > 0, 'got results within range');
	$res = $ro->query('d:20101003..');
	is(scalar @{$res->{msgs}}, 0, 'nothing after 20101003');
	$res = $ro->query('d:..19931001');
	is(scalar @{$res->{msgs}}, 0, 'nothing before 19931001');
}

# names and addresses
{
	my $res = $ro->query('t:list@example.com');
	is(scalar @{$res->{msgs}}, 6, 'searched To: successfully');
	foreach my $smsg (@{$res->{msgs}}) {
		like($smsg->to, qr/\blist\@example\.com\b/, 'to appears');
	}

	$res = $ro->query('tc:list@example.com');
	is(scalar @{$res->{msgs}}, 6, 'searched To+Cc: successfully');
	foreach my $smsg (@{$res->{msgs}}) {
		my $tocc = join("\n", $smsg->to, $smsg->cc);
		like($tocc, qr/\blist\@example\.com\b/, 'tocc appears');
	}

	foreach my $pfx ('tcf:', 'c:') {
		$res = $ro->query($pfx . 'foo@example.com');
		is(scalar @{$res->{msgs}}, 1,
			"searched $pfx successfully for Cc:");
		foreach my $smsg (@{$res->{msgs}}) {
			like($smsg->cc, qr/\bfoo\@example\.com\b/,
				'cc appears');
		}
	}

	foreach my $pfx ('', 'tcf:', 'f:') {
		$res = $ro->query($pfx . 'Laggy');
		is(scalar @{$res->{msgs}}, 1,
			"searched $pfx successfully for From:");
		foreach my $smsg (@{$res->{msgs}}) {
			like($smsg->from, qr/Laggy Sender/,
				"From appears with $pfx");
		}
	}
}

{
	$rw_commit->();
	$ro->reopen;
	my $res = $ro->query('b:hello');
	is(scalar @{$res->{msgs}}, 0, 'no match on body search only');
	$res = $ro->query('bs:smith');
	is(scalar @{$res->{msgs}}, 0,
		'no match on body+subject search for From');

	$res = $ro->query('q:theatre');
	is(scalar @{$res->{msgs}}, 1, 'only one quoted body');
	like($res->{msgs}->[0]->from, qr/\AQuoter/, 'got quoted body');

	$res = $ro->query('nq:theatre');
	is(scalar @{$res->{msgs}}, 1, 'only one non-quoted body');
	like($res->{msgs}->[0]->from, qr/\ANon-Quoter/, 'got non-quoted body');

	foreach my $pfx (qw(b: bs:)) {
		$res = $ro->query($pfx . 'theatre');
		is(scalar @{$res->{msgs}}, 2, "searched both bodies for $pfx");
		like($res->{msgs}->[0]->from, qr/\ANon-Quoter/,
			"non-quoter first for $pfx");
	}
}

{
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
	is(scalar @{$n->{msgs}}, 1, 'got result for n:');
	my $res = $ro->query('part_deux.txt');
	is(scalar @{$res->{msgs}}, 1, 'got result without n:');
	is($n->{msgs}->[0]->mid, $res->{msgs}->[0]->mid,
		'same result with and without');
	my $txt = $ro->query('"inside another"');
	is($txt->{msgs}->[0]->mid, $res->{msgs}->[0]->mid,
		'search inside text attachments works');
}
$rw->commit_txn_lazy;

done_testing();

1;
