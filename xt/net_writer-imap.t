#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
use Sys::Hostname qw(hostname);
use POSIX qw(strftime);
use PublicInbox::OnDestroy;
use PublicInbox::URIimap;
use PublicInbox::Config;
use PublicInbox::DS;
use PublicInbox::InboxIdle;
use Fcntl qw(O_EXCL O_WRONLY O_CREAT);
my $imap_url = $ENV{TEST_IMAP_WRITE_URL} or
	plan skip_all => 'TEST_IMAP_WRITE_URL unset';
my $uri = PublicInbox::URIimap->new($imap_url);
defined($uri->path) and
	plan skip_all => "$imap_url should not be a mailbox (just host:port)";
require_mods('Mail::IMAPClient');
require_ok 'PublicInbox::NetWriter';
my $host = (split(/\./, hostname))[0];
my ($base) = ($0 =~ m!\b([^/]+)\.[^\.]+\z!);
my $SEP = $ENV{IMAP_SEPARATOR} || '.';
my $folder = "INBOX$SEP$base-$host-".strftime('%Y%m%d%H%M%S', gmtime(time)).
		"-$$-".sprintf('%x', int(rand(0xffffffff)));
my $nwr = PublicInbox::NetWriter->new;
chop($imap_url) if substr($imap_url, -1) eq '/';
my $folder_url = "$imap_url/$folder";
my $folder_uri = PublicInbox::URIimap->new($folder_url);
is($folder_uri->mailbox, $folder, 'folder correct') or
		BAIL_OUT "BUG: bad $$uri";
$nwr->add_url($$folder_uri);
is($nwr->errors, undef, 'no errors');
$nwr->{pi_cfg} = bless {}, 'PublicInbox::Config';

my $set_cred_helper = sub {
	my ($f, $cred_set) = @_;
	sysopen(my $fh, $f, O_CREAT|O_EXCL|O_WRONLY) or BAIL_OUT "open $f: $!";
	print $fh <<EOF or BAIL_OUT "print $f: $!";
[credential]
	helper = $cred_set
EOF
	close $fh or BAIL_OUT "close $f: $!";
};

# allow testers with git-credential-store configured to reuse
# stored credentials inside test_lei(sub {...}) when $ENV{HOME}
# is overridden and localized.
my ($cred_set, @cred_link, $tmpdir, $for_destroy);
chomp(my $cred_helper = `git config credential.helper 2>/dev/null`);
if ($cred_helper eq 'store') {
	my $config = $ENV{XDG_CONFIG_HOME} // "$ENV{HOME}/.config";
	for my $f ("$ENV{HOME}/.git-credentials", "$config/git/credentials") {
		next unless -f $f;
		@cred_link = ($f, '/.git-credentials');
		last;
	}
	$cred_set = qq("$cred_helper");
} elsif ($cred_helper =~ /\Acache(?:[ \t]|\z)/) {
	my $cache = $ENV{XDG_CACHE_HOME} // "$ENV{HOME}/.cache";
	for my $d ("$ENV{HOME}/.git-credential-cache",
			"$cache/git/credential") {
		next unless -d $d;
		@cred_link = ($d, '/.git-credential-cache');
		$cred_set = qq("$cred_helper");
		last;
	}
} elsif (!$cred_helper) { # make the test less painful if no creds configured
	($tmpdir, $for_destroy) = tmpdir;
	my $d = "$tmpdir/.git-credential-cache";
	mkdir($d, 0700) or BAIL_OUT $!;
	$cred_set = "cache --timeout=60";
	@cred_link = ($d, '/.git-credential-cache');
} else {
	diag "credential.helper=$cred_helper will not be used for this test";
}

my $mics = do {
	local $ENV{HOME} = $tmpdir // $ENV{HOME};
	if ($tmpdir && $cred_set) {
		$set_cred_helper->("$ENV{HOME}/.gitconfig", $cred_set)
	}
	$nwr->imap_common_init;
};
my $mic = (values %$mics)[0];
my $cleanup = PublicInbox::OnDestroy->new($$, sub {
	if (defined($folder)) {
		my $mic = $nwr->mic_get($uri);
		$mic->delete($folder) or
			fail "delete $folder <$folder_uri>: $@";
	}
	if ($tmpdir && -f "$tmpdir/.gitconfig") {
		local $ENV{HOME} = $tmpdir;
		system(qw(git credential-cache exit));
	}
});
my $imap_append = $nwr->can('imap_append');
my $smsg = bless { kw => [ 'seen' ] }, 'PublicInbox::Smsg';
$imap_append->($mic, $folder, undef, $smsg, eml_load('t/plack-qp.eml'));
$nwr->{quiet} = 1;
my $imap_slurp_all = sub {
	my ($url, $uid, $kw, $eml, $res) = @_;
	push @$res, [ $kw, $eml ];
};
$nwr->imap_each($folder_uri, $imap_slurp_all, my $res = []);
is(scalar(@$res), 1, 'got appended message');
my $plack_qp_eml = eml_load('t/plack-qp.eml');
is_deeply($res, [ [ [ 'seen' ], $plack_qp_eml ] ],
	'uploaded message read back');
$res = $mic = $mics = undef;

test_lei(sub {
	my ($ro_home, $cfg_path) = setup_public_inboxes;
	my $cfg = PublicInbox::Config->new($cfg_path);
	$cfg->each_inbox(sub {
		my ($ibx) = @_;
		lei_ok qw(add-external -q), $ibx->{inboxdir} or BAIL_OUT;
	});

	# cred_link[0] may be on a different (hopefully encrypted) FS,
	# we only symlink to it here, so we don't copy any sensitive data
	# into the temporary directory
	if (@cred_link && !symlink($cred_link[0], $ENV{HOME}.$cred_link[1])) {
		diag "symlink @cred_link: $! (non-fatal)";
		$cred_set = undef;
	}
	$set_cred_helper->("$ENV{HOME}/.gitconfig", $cred_set) if $cred_set;

	# don't combine these two:
	$ENV{TEST_IMAP_COMPRESS} and lei_ok qw(config imap.compress true);
	$ENV{TEST_IMAP_DEBUG} and lei_ok qw(config imap.debug true);
	my $proxy = $ENV{TEST_IMAP_PROXY};
	lei_ok(qw(config imap.proxy), $proxy) if $proxy;

	lei_ok qw(q f:qp@example.com -o), $folder_url;
	$nwr->imap_each($folder_uri, $imap_slurp_all, my $res = []);
	is(scalar(@$res), 1, 'got one deduped result') or diag explain($res);
	is_deeply($res->[0]->[1], $plack_qp_eml,
			'lei q wrote expected result');

	my $mdir = "$ENV{HOME}/t.mdir";
	lei_ok 'convert', $folder_url, '-o', $mdir;
	my @mdfiles = glob("$mdir/*/*");
	is(scalar(@mdfiles), 1, '1 message from IMAP => Maildir conversion');
	is_deeply(eml_load($mdfiles[0]), $plack_qp_eml,
		'conversion from IMAP to Maildir');

	lei_ok qw(q f:matz -a -o), $folder_url;
	$nwr->imap_each($folder_uri, $imap_slurp_all, my $aug = []);
	is(scalar(@$aug), 2, '2 results after augment') or diag explain($aug);
	my $exp = $res->[0]->[1]->as_string;
	is(scalar(grep { $_->[1]->as_string eq $exp } @$aug), 1,
			'original remains after augment');
	$exp = eml_load('t/iso-2202-jp.eml')->as_string;
	is(scalar(grep { $_->[1]->as_string eq $exp } @$aug), 1,
			'new result shown after augment');

	lei_ok qw(q s:thisbetternotgiveanyresult -o), $folder_url;
	$nwr->imap_each($folder_uri, $imap_slurp_all, my $empty = []);
	is(scalar(@$empty), 0, 'no results w/o augment');

	my $f = 't/utf8.eml'; # <testmessage@example.com>
	$exp = eml_load($f);
	lei_ok qw(convert -F eml -o), $folder_url, $f;
	my (@uid, @res);
	$nwr->imap_each($folder_uri, sub {
		my ($u, $uid, $kw, $eml) = @_;
		push @uid, $uid;
		push @res, [ $kw, $eml ];
	});
	is_deeply(\@res, [ [ [], $exp ] ], 'converted to IMAP destination');
	is(scalar(@uid), 1, 'got one UID back');
	lei_ok qw(q -o /dev/stdout m:testmessage@example.com --no-external);
	is_deeply(json_utf8->decode($lei_out), [undef],
		'no results before import');

	lei_ok qw(import -F eml), $f, \'import local copy w/o keywords';

	lei_ok 'import', $folder_url; # populate mail_sync.sqlite3
	lei_ok qw(tag +kw:seen +kw:answered +kw:flagged), $f;
	lei_ok 'ls-mail-sync';
	my @ls = split(/\n/, $lei_out);
	is(scalar(@ls), 1, 'only one folder in ls-mail-sync') or xbail(\@ls);
	for my $l (@ls) {
		like($l, qr/;UIDVALIDITY=\d+\z/, 'UIDVALIDITY');
	}
	lei_ok 'export-kw', $folder_url;
	$mic = $nwr->mic_for_folder($folder_uri);
	my $flags = $mic->flags($uid[0]);
	is_deeply([sort @$flags], [ qw(\\Answered \\Flagged \\Seen) ],
		'IMAP flags set by export-kw') or diag explain($flags);

	# ensure this imap_set_kw clobbers
	$nwr->imap_set_kw($mic, $uid[0], [ 'seen' ])->expunge or
		BAIL_OUT "expunge $@";
	$mic = undef;
	@res = ();
	$nwr->imap_each($folder_uri, $imap_slurp_all, \@res);
	is_deeply(\@res, [ [ ['seen'], $exp ] ], 'seen flag set') or
		diag explain(\@res);

	lei_ok qw(q s:thisbetternotgiveanyresult -o), $folder_url,
		\'clobber folder but import flag';
	$nwr->imap_each($folder_uri, $imap_slurp_all, $empty = []);
	is_deeply($empty, [], 'clobbered folder');
	lei_ok qw(q -o /dev/stdout m:testmessage@example.com --no-external);
	$res = json_utf8->decode($lei_out)->[0];
	is_deeply([@$res{qw(m kw)}], ['testmessage@example.com', ['seen']],
		'kw set');

	# prepare messages for watch
	$mic = $nwr->mic_for_folder($folder_uri);
	for my $kw (qw(Deleted Seen Answered Draft forwarded)) {
		my $buf = <<EOM;
From: x\@example.com
Message-ID: <$kw\@test.example.com>

EOM
		my $f = $kw eq 'forwarded' ? '$Forwarded' : "\\$kw";
		$mic->append_string($folder_uri->mailbox, $buf, $f)
			or BAIL_OUT "append $kw $@";
	}
	$mic->disconnect;

	my $inboxdir = "$ENV{HOME}/wtest";
	my @cmd = (qw(-init -Lbasic wtest), $inboxdir,
			qw(https://example.com/wtest wtest@example.com));
	run_script(\@cmd) or BAIL_OUT "init wtest";
	xsys(qw(git config), "--file=$ENV{HOME}/.public-inbox/config",
			'publicinbox.wtest.watch',
			$folder_url) == 0 or BAIL_OUT "git config $?";
	my $watcherr = "$ENV{HOME}/watch.err";
	open my $err_wr, '>>', $watcherr or BAIL_OUT $!;
	my $pub_cfg = PublicInbox::Config->new;
	PublicInbox::DS->Reset;
	my $ii = PublicInbox::InboxIdle->new($pub_cfg);
	my $cb = sub { PublicInbox::DS->SetPostLoopCallback(sub {}) };
	my $obj = bless \$cb, 'PublicInbox::TestCommon::InboxWakeup';
	$pub_cfg->each_inbox(sub { $_[0]->subscribe_unlock('ident', $obj) });
	my $w = start_script(['-watch'], undef, { 2 => $err_wr });
	diag 'waiting for initial fetch...';
	PublicInbox::DS::event_loop();
	my $ibx = $pub_cfg->lookup_name('wtest');
	my $mm = $ibx->mm;
	ok(defined($mm->num_for('Seen@test.example.com')),
		'-watch takes seen message');
	ok(defined($mm->num_for('Answered@test.example.com')),
		'-watch takes answered message');
	ok(!defined($mm->num_for('Deleted@test.example.com')),
		'-watch ignored \\Deleted');
	ok(!defined($mm->num_for('Draft@test.example.com')),
		'-watch ignored \\Draft');
	ok(defined($mm->num_for('forwarded@test.example.com')),
		'-watch takes forwarded message');
	undef $w; # done with watch
	lei_ok qw(import), $folder_url;
	lei_ok qw(q m:forwarded@test.example.com);
	is_deeply(json_utf8->decode($lei_out)->[0]->{kw}, ['forwarded'],
		'forwarded kw imported from IMAP');

	lei_ok qw(q m:testmessage --no-external -o), $folder_url;
	lei_ok qw(up), $folder_url;
	lei_ok qw(up --all=remote);
	$mic = $nwr->mic_get($uri);
	$mic->delete($folder) or fail "delete $folder <$folder_uri>: $@";
	$mic->expunge;
	undef $mic;
	undef $folder;
	ok(!lei(qw(export-kw), $folder_url),
		'export-kw fails w/ non-existent folder');

});

undef $cleanup; # remove temporary folder
done_testing;
