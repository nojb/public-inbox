# Copyright (C) 2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::MIME;
use PublicInbox::ContentId qw(content_digest);
use File::Temp qw/tempdir/;
foreach my $mod (qw(DBD::SQLite Search::Xapian)) {
	eval "require $mod";
	plan skip_all => "$mod missing for nntpd.t" if $@;
}
use_ok 'PublicInbox::V2Writable';
my $mainrepo = tempdir('pi-v2writable-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $ibx = {
	mainrepo => $mainrepo,
	name => 'test-v2writable',
	version => 2,
	-primary_address => 'test@example.com',
};
$ibx = PublicInbox::Inbox->new($ibx);
my $mime = PublicInbox::MIME->create(
	header => [
		From => 'a@example.com',
		To => 'test@example.com',
		Subject => 'this is a subject',
		'Message-ID' => '<a-mid@b>',
		Date => 'Fri, 02 Oct 1993 00:00:00 +0000',
	],
	body => "hello world\n",
);

my $im = eval {
	local $ENV{NPROC} = '1';
	PublicInbox::V2Writable->new($ibx, 1);
};
is($im->{partitions}, 1, 'one partition when forced');
ok($im->add($mime), 'ordinary message added');
my $git0;

if ('ensure git configs are correct') {
	my @cmd = (qw(git config), "--file=$mainrepo/all.git/config",
		qw(core.sharedRepository 0644));
	is(system(@cmd), 0, "set sharedRepository in all.git");
	$git0 = PublicInbox::Git->new("$mainrepo/git/0.git");
	chomp(my $v = $git0->qx(qw(config core.sharedRepository)));
	is($v, '0644', 'child repo inherited core.sharedRepository');
	chomp($v = $git0->qx(qw(config --bool repack.writeBitmaps)));
	is($v, 'true', 'child repo inherited repack.writeBitmaps');
}

{
	my @warn;
	local $SIG{__WARN__} = sub { push @warn, @_ };
	is($im->add($mime), undef, 'obvious duplicate rejected');
	is(scalar(@warn), 0, 'no warning about resent message');

	@warn = ();
	$mime->header_set('Message-Id', '<a-mid@b>', '<c@d>');
	is($im->add($mime), undef, 'secondary MID ignored if first matches');
	my $sec = PublicInbox::MIME->new($mime->as_string);
	$sec->header_set('Date');
	$sec->header_set('Message-Id', '<a-mid@b>', '<c@d>');
	ok($im->add($sec), 'secondary MID used if data is different');
	like(join(' ', @warn), qr/mismatched/, 'warned about mismatch');
	like(join(' ', @warn), qr/alternative/, 'warned about alternative');
	is_deeply([ '<a-mid@b>', '<c@d>' ],
		[ $sec->header_obj->header_raw('Message-Id') ],
		'no new Message-Id added');

	my $sane_mid = qr/\A<[\w\-]+\@localhost>\z/;
	@warn = ();
	$mime->header_set('Message-Id', '<a-mid@b>');
	$mime->body_set('different');
	ok($im->add($mime), 'reused mid ok');
	like(join(' ', @warn), qr/reused/, 'warned about reused MID');
	my @mids = $mime->header_obj->header_raw('Message-Id');
	is($mids[0], '<a-mid@b>', 'original mid not changed');
	like($mids[1], $sane_mid, 'new MID added');
	is(scalar(@mids), 2, 'only one new MID added');

	@warn = ();
	$mime->header_set('Message-Id', '<a-mid@b>');
	$mime->body_set('this one needs a random mid');
	my $gen = PublicInbox::Import::digest2mid(content_digest($mime));
	unlike($gen, qr![\+/=]!, 'no URL-unfriendly chars in Message-Id');
	my $fake = PublicInbox::MIME->new($mime->as_string);
	$fake->header_set('Message-Id', "<$gen>");
	ok($im->add($fake), 'fake added easily');
	is_deeply(\@warn, [], 'no warnings from a faker');
	ok($im->add($mime), 'random MID made');
	like(join(' ', @warn), qr/using random/, 'warned about using random');
	@mids = $mime->header_obj->header_raw('Message-Id');
	is($mids[0], '<a-mid@b>', 'original mid not changed');
	like($mids[1], $sane_mid, 'new MID added');
	is(scalar(@mids), 2, 'only one new MID added');

	@warn = ();
	$mime->header_set('Message-Id');
	ok($im->add($mime), 'random MID made for MID free message');
	@mids = $mime->header_obj->header_raw('Message-Id');
	like($mids[0], $sane_mid, 'mid was generated');
	is(scalar(@mids), 1, 'new generated');
}

{
	$mime->header_set('Message-Id', '<abcde@1>', '<abcde@2>');
	ok($im->add($mime), 'message with multiple Message-ID');
	$im->done;
	my @found;
	my $srch = $ibx->search;
	$srch->reopen->each_smsg_by_mid('abcde@1', sub { push @found, @_; 1 });
	is(scalar(@found), 1, 'message found by first MID');
	$srch->reopen->each_smsg_by_mid('abcde@2', sub { push @found, @_; 1 });
	is(scalar(@found), 2, 'message found by second MID');
	is($found[0]->{doc_id}, $found[1]->{doc_id}, 'same document');
	ok($found[1]->{doc_id} > 0, 'doc_id is positive');
}

SKIP: {
	use Fcntl qw(FD_CLOEXEC F_SETFD F_GETFD);
	use Net::NNTP;
	use IO::Socket;
	use Socket qw(SO_KEEPALIVE IPPROTO_TCP TCP_NODELAY);
	eval { require Danga::Socket };
	skip "Danga::Socket missing $@", 2 if $@;
	my $err = "$mainrepo/stderr.log";
	my $out = "$mainrepo/stdout.log";
	my %opts = (
		LocalAddr => '127.0.0.1',
		ReuseAddr => 1,
		Proto => 'tcp',
		Type => SOCK_STREAM,
		Listen => 1024,
	);
	my $group = 'inbox.comp.test.v2writable';
	my $pi_config = "$mainrepo/pi_config";
	open my $fh, '>', $pi_config or die "open: $!\n";
	print $fh <<EOF
[publicinbox "test-v2writable"]
	mainrepo = $mainrepo
	version = 2
	address = test\@example.com
	newsgroup = $group
EOF
	;
	close $fh or die "close: $!\n";
	my $sock = IO::Socket::INET->new(%opts);
	ok($sock, 'sock created');
	my $pid;
	my $len;
	END { kill 'TERM', $pid if defined $pid };
	$! = 0;
	my $fl = fcntl($sock, F_GETFD, 0);
	ok(! $!, 'no error from fcntl(F_GETFD)');
	is($fl, FD_CLOEXEC, 'cloexec set by default (Perl behavior)');
	$pid = fork;
	if ($pid == 0) {
		use POSIX qw(dup2);
		$ENV{PI_CONFIG} = $pi_config;
		# pretend to be systemd
		fcntl($sock, F_SETFD, $fl &= ~FD_CLOEXEC);
		dup2(fileno($sock), 3) or die "dup2 failed: $!\n";
		$ENV{LISTEN_PID} = $$;
		$ENV{LISTEN_FDS} = 1;
		my $nntpd = 'blib/script/public-inbox-nntpd';
		exec $nntpd, "--stdout=$out", "--stderr=$err";
		die "FAIL: $!\n";
	}
	ok(defined $pid, 'forked nntpd process successfully');
	$! = 0;
	fcntl($sock, F_SETFD, $fl |= FD_CLOEXEC);
	ok(! $!, 'no error from fcntl(F_SETFD)');
	my $host_port = $sock->sockhost . ':' . $sock->sockport;
	my $n = Net::NNTP->new($host_port);
	$n->group($group);
	my $x = $n->xover('1-');
	my %uniq;
	foreach my $num (sort { $a <=> $b } keys %$x) {
		my $mid = $x->{$num}->[3];
		is($uniq{$mid}++, 0, "MID for $num is unique in XOVER");
		is_deeply($n->xhdr('Message-ID', $num),
			 { $num => $mid }, "XHDR lookup OK on num $num");
		is_deeply($n->xhdr('Message-ID', $mid),
			 { $mid => $mid }, "XHDR lookup OK on MID $num");
	}
	my %nn;
	foreach my $mid (@{$n->newnews(0, $group)}) {
		is($nn{$mid}++, 0, "MID is unique in NEWNEWS");
	}
	is_deeply([sort keys %nn], [sort keys %uniq]);
};
{
	local $ENV{NPROC} = 2;
	my @before = $git0->qx(qw(log --pretty=oneline));
	my $before = $git0->qx(qw(log --pretty=raw --raw -r --no-abbrev));
	$im = PublicInbox::V2Writable->new($ibx, 1);
	is($im->{partitions}, 1, 'detected single partition from previous');
	my $smsg = $im->remove($mime, 'test removal');
	my @after = $git0->qx(qw(log --pretty=oneline));
	$im->done;
	my $tip = shift @after;
	like($tip, qr/\A[a-f0-9]+ test removal\n\z/s,
		'commit message propaged to git');
	is_deeply(\@after, \@before, 'only one commit written to git');
	is($ibx->mm->num_for($smsg->mid), undef, 'no longer in Msgmap by mid');
	like($smsg->num, qr/\A\d+\z/, 'numeric number in return message');
	is($ibx->mm->mid_for($smsg->num), undef, 'no longer in Msgmap by num');
	my $srch = $ibx->search->reopen;
	my @found = ();
	$srch->each_smsg_by_mid($smsg->mid, sub { push @found, @_; 1 });
	is(scalar(@found), 0, 'no longer found in Xapian skeleton');
	my @log1 = qw(log -1 --pretty=raw --raw -r --no-abbrev --no-renames);

	my $after = $git0->qx(@log1);
	if ($after =~ m!( [a-f0-9]+ )A\td$!m) {
		my $oid = $1;
		ok(index($before, $oid) > 0, 'no new blob introduced');
	} else {
		fail('failed to extract blob from log output');
	}
	is($im->remove($mime, 'test removal'), undef,
		'remove is idempotent');
	$im->done;
	is($git0->qx(@log1),
		$after, 'no git history made with idempotent remove');
	eval { $im->done };
	ok(!$@, '->done is idempotent');
}

{
	ok($im->add($mime), 'add message to be purged');
	local $SIG{__WARN__} = sub {};
	ok($im->purge($mime), 'purged message');
	$im->done;
}

{
	my @warn;
	my $x = 'x'x250;
	my $y = 'y'x250;
	local $SIG{__WARN__} = sub { push @warn, @_ };
	$mime->header_set('Subject', 'long mid');
	$mime->header_set('Message-ID', "<$x>");
	ok($im->add($mime), 'add excessively long Message-ID');

	$mime->header_set('Message-ID', "<$y>");
	$mime->header_set('References', "<$x>");
	ok($im->add($mime), 'add excessively long References');
	$im->barrier;

	my $msgs = $ibx->search->reopen->get_thread('x'x244)->{msgs};
	is(2, scalar(@$msgs), 'got both messages');
	is($msgs->[0]->{mid}, 'x'x244, 'stored truncated mid');
	is($msgs->[1]->{references}, '<'.('x'x244).'>', 'stored truncated ref');
	is($msgs->[1]->{mid}, 'y'x244, 'stored truncated mid(2)');
	$im->done;
}

done_testing();
