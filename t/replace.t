# Copyright (C) 2019-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::Eml;
use PublicInbox::InboxWritable;
use PublicInbox::TestCommon;
use Cwd qw(abs_path);
require_git(2.6); # replace is v2 only, for now...
require_mods(qw(DBD::SQLite));
local $ENV{HOME} = abs_path('t');

sub test_replace ($$$) {
	my ($v, $level, $opt) = @_;
	diag "v$v $level replace";
	my $this = "pi-$v-$level-replace";
	my ($tmpdir, $for_destroy) = tmpdir($this);
	my $ibx = PublicInbox::Inbox->new({
		inboxdir => "$tmpdir/testbox",
		name => $this,
		version => $v,
		-no_fsync => 1,
		-primary_address => 'test@example.com',
		indexlevel => $level,
	});

	my $orig = PublicInbox::Eml->new(<<'EOF');
From: Barbra Streisand <effect@example.com>
To: test@example.com
Subject: confidential
Message-ID: <replace@example.com>
Date: Fri, 02 Oct 1993 00:00:00 +0000

Top secret info about my house in Malibu...
EOF
	my $im = PublicInbox::InboxWritable->new($ibx, {nproc=>1})->importer(0);
	# fake a bunch of epochs
	$im->{rotate_bytes} = $opt->{rotate_bytes} if $opt->{rotate_bytes};

	if ($opt->{pre}) {
		$opt->{pre}->($im, 1, 2);
		$orig->header_set('References', '<1@example.com>');
	}
	ok($im->add($orig), 'add message to be replaced');
	if ($opt->{post}) {
		$opt->{post}->($im, 3, { 4 => 'replace@example.com' });
	}
	$im->done;
	my $thread_a = $ibx->over->get_thread('replace@example.com');

	my %before = map {; delete($_->{blob}) => $_ } @{$ibx->over->recent};
	my $reject = PublicInbox::Eml->new($orig->as_string);
	foreach my $mid (['<replace@example.com>', '<extra@example.com>'],
				[], ['<replaced@example.com>']) {
		$reject->header_set('Message-ID', @$mid);
		my $ok = eval { $im->replace($orig, $reject) };
		like($@, qr/Message-ID.*may not be changed/,
			'->replace died on Message-ID change');
		ok(!$ok, 'no replacement happened');
	}

	# prepare the replacement
	my $expect = "Move along, nothing to see here\n";
	my $repl = PublicInbox::Eml->new($orig->as_string);
	$repl->header_set('From', '<redactor@example.com>');
	$repl->header_set('Subject', 'redacted');
	$repl->header_set('Date', 'Sat, 02 Oct 2010 00:00:00 +0000');
	$repl->body_str_set($expect);

	my @warn;
	local $SIG{__WARN__} = sub { push @warn, @_ };
	ok(my $cmts = $im->replace($orig, $repl), 'replaced message');
	my $changed_epochs = 0;
	for my $tip (@$cmts) {
		next if !defined $tip;
		$changed_epochs++;
		like($tip, qr/\A[a-f0-9]{40,}\z/,
			'replace returned current commit');
	}
	is($changed_epochs, 1, 'only one epoch changed');

	$im->done;
	my $m = PublicInbox::Eml->new($ibx->msg_by_mid('replace@example.com'));
	is($m->body, $expect, 'replaced message');
	is_deeply(\@warn, [], 'no warnings on noop');

	my @cat = qw(cat-file --buffer --batch --batch-all-objects);
	my $git = $ibx->git;
	my @all = $git->qx(@cat);
	is_deeply([grep(/confidential/, @all)], [], 'nothing confidential');
	is_deeply([grep(/Streisand/, @all)], [], 'Streisand who?');
	is_deeply([grep(/\bOct 1993\b/, @all)], [], 'nothing from Oct 1993');
	my $t19931002 = qr/ 749520000 /;
	is_deeply([grep(/$t19931002/, @all)], [], "nothing matches $t19931002");

	for my $dir (glob("$ibx->{inboxdir}/git/*.git")) {
		my ($bn) = ($dir =~ m!([^/]+)\z!);
		is(xsys(qw(git --git-dir), $dir,
					qw(fsck --strict --no-progress)),
			0, "git fsck is clean in epoch $bn");
	}

	my $thread_b = $ibx->over->get_thread('replace@example.com');
	is_deeply([sort map { $_->{mid} } @$thread_b],
		[sort map { $_->{mid} } @$thread_a], 'threading preserved');

	if (my $srch = $ibx->search) {
		for my $q ('f:streisand', 's:confidential', 'malibu') {
			my $mset = $srch->mset($q);
			is($mset->size, 0, "no match for $q");
		}
		my @ok = ('f:redactor', 's:redacted', 'nothing to see');
		if ($opt->{pre}) {
			push @ok, 'm:1@example.com', 'm:2@example.com',
				's:message2', 's:message1';
		}
		if ($opt->{post}) {
			push @ok, 'm:3@example.com', 'm:4@example.com',
				's:message3', 's:message4';
		}
		for my $q (@ok) {
			my $mset = $srch->mset($q);
			ok($mset->size, "got match for $q");
		}
	}

	# check overview matches:
	my %after = map {; delete($_->{blob}) => $_ } @{$ibx->over->recent};
	my @before_blobs = keys %before;
	foreach my $blob (@before_blobs) {
		delete $before{$blob} if delete $after{$blob};
	}

	is(scalar keys %before, 1, 'one unique blob from before left');
	is(scalar keys %after, 1, 'one unique blob from after left');
	foreach my $blob (keys %before) {
		is($git->check($blob), undef, 'old blob not found');
		my $smsg = $before{$blob};
		is($smsg->{subject}, 'confidential', 'before subject');
		is($smsg->{mid}, 'replace@example.com', 'before MID');
	}
	foreach my $blob (keys %after) {
		ok($git->check($blob), 'new blob found');
		my $smsg = $after{$blob};
		is($smsg->{subject}, 'redacted', 'after subject');
		is($smsg->{mid}, 'replace@example.com', 'before MID');
	}
	# $git->cleanup; # needed if $im->{parallel};
	@warn = ();
	is($im->replace($orig, $repl), undef, 'no-op replace returns undef');
	is($im->purge($orig), undef, 'no-op purge returns undef');
	is_deeply(\@warn, [], 'no warnings on noop');
	# $im->done; # needed if $im->{parallel}
}

sub pad_msgs {
	my ($im, @range) = @_;
	for my $i (@range) {
		my $irt;
		if (ref($i) eq 'HASH') {
			($i, $irt) = each %$i;
		}
		my $sec = sprintf('%0d', $i);
		my $mime = PublicInbox::Eml->new(<<EOF);
From: foo\@example.com
To: test\@example.com
Message-ID: <$i\@example.com>
Date: Fri, 02, Jan 1970 00:00:$sec +0000
Subject: message$i

message number$i
EOF

		if (defined($irt)) {
			$mime->header_set('References', "<$irt>");
		}

		$im->add($mime);
	}
}

my $opt = { pre => \&pad_msgs };
test_replace(2, 'basic', {});
test_replace(2, 'basic', $opt);
test_replace(2, 'basic', $opt = { %$opt, post => \&pad_msgs });
test_replace(2, 'basic', $opt = { %$opt, rotate_bytes => 1 });

SKIP: {
	require_mods(qw(Search::Xapian), 8);
	for my $l (qw(medium)) {
		test_replace(2, $l, {});
		$opt = { pre => \&pad_msgs };
		test_replace(2, $l, $opt);
		test_replace(2, $l, $opt = { %$opt, post => \&pad_msgs });
		test_replace(2, $l, $opt = { %$opt, rotate_bytes => 1 });
	}
};

done_testing();
