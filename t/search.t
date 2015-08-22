# Copyright (C) 2015, all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
use strict;
use warnings;
use Test::More;
eval { require PublicInbox::SearchIdx; };
plan skip_all => "Xapian missing for search" if $@;
use File::Temp qw/tempdir/;
use Email::MIME;
use Data::Dumper;
my $tmpdir = tempdir(CLEANUP => 1);
my $git_dir = "$tmpdir/a.git";
my ($root_id, $last_id);

is(0, system(qw(git init -q --bare), $git_dir), "git init (main)");
eval { PublicInbox::Search->new($git_dir) };
ok($@, "exception raised on non-existent DB");

my $rw = PublicInbox::SearchIdx->new($git_dir, 1);
my $ro = PublicInbox::Search->new($git_dir);
my $rw_commit = sub {
	$rw = undef;
	$rw = PublicInbox::SearchIdx->new($git_dir, 1);
};

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
		],
		body => "goodbye forever :<\n");

	my $rv;
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
	my $found = $ro->lookup_message('<root@s>');
	ok($found, "message found");
	is($root_id, $found->{doc_id}, 'doc_id set correctly');
	$found->ensure_metadata;
	is($found->mid, 'root@s', 'mid set correctly');
	ok(int($found->thread_id) > 0, 'thread_id is an integer');

	my @exp = sort qw(root@s last@s);
	my $res = $ro->query("path:hello_world");
	my @res = filter_mids($res);
	is_deeply(\@res, \@exp, 'got expected results for path: match');

	foreach my $p (qw(hello hello_ hello_world2 hello_world_)) {
		$res = $ro->query("path:$p");
		is($res->{total}, 0, "path variant `$p' does not match");
	}

	$res = $ro->query('subject:(Hello world)');
	@res = filter_mids($res);
	is_deeply(\@res, \@exp, 'got expected results for subject:() match');

	$res = $ro->query('subject:"Hello world"');
	@res = filter_mids($res);
	is_deeply(\@res, \@exp, 'got expected results for subject:"" match');

	$res = $ro->query('subject:"Hello world"', {limit => 1});
	is(scalar @{$res->{msgs}}, 1, "limit works");
	my $first = $res->{msgs}->[0];

	$res = $ro->query('subject:"Hello world"', {offset => 1});
	is(scalar @{$res->{msgs}}, 1, "offset works");
	my $second = $res->{msgs}->[0];

	isnt($first, $second, "offset returned different result from limit");

	foreach my $f (qw(inreplyto references)) {
		$res = $ro->query($f . ':root@s');
		@res = filter_mids($res);
		is_deeply(\@res, [ 'last@s' ],
			  "got expected results for $f: match");
		$res = $ro->query($f . ':root');
		is($res->{total}, 0, "no partial mid match");
	}
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
	ok($ghost_id < $reply_id, "ghost vivified from earlier message");
}

# search thread on ghost
{
	$rw_commit->();
	$ro->reopen;

	# Subject:
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
	my $long_midc = Digest::SHA::sha1_hex($long_mid);

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
	my $res = $ro->query('references:root@s');
	my @res = filter_mids($res);
	is_deeply(\@res, [ sort('last@s', $long_midc) ],
		  "got expected results for references: match");

	my $followups = $ro->get_followups('root@s');
	$followups = [ filter_mids($followups) ];
	is_deeply($followups, [ filter_mids($res) ], "get_followups matches");

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
	my @exp = sort($long_reply_mid, 'root@s', 'last@s', $long_midc);
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
	my $doc_id = $rw->add_message(Email::MIME->create(
		header_str => [
			Date => 'Sat, 02 Oct 2010 00:00:01 +0000',
			Subject => 'Circle',
			'Message-ID' => '<circle@a>',
			'References' => '<circle@a>',
			'In-Reply-To' => '<circle@a>',
			From => 'Circle <circle@example.com>',
			To => 'list@example.com',
		],
		body => "LOOP!\n"));
	ok($doc_id > 0, "doc_id defined with circular reference");
	my $smsg = $rw->lookup_message('circle@a');
	$smsg->ensure_metadata;
	is($smsg->{references}, undef, "no references created");
}

done_testing();

1;
