#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
use Sys::Hostname qw(hostname);
use POSIX qw(strftime);
use PublicInbox::OnDestroy;
use PublicInbox::URIimap;
use PublicInbox::Config;
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
my $folder = "INBOX.$base-$host-".strftime('%Y%m%d%H%M%S', gmtime(time)).
		"-$$-".sprintf('%x', int(rand(0xffffffff)));
my $nwr = PublicInbox::NetWriter->new;
chop($imap_url) if substr($imap_url, -1) eq '/';
my $folder_uri = PublicInbox::URIimap->new("$imap_url/$folder");
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
	my $mic = $nwr->mic_get($imap_url);
	$mic->delete($folder) or fail "delete $folder <$folder_uri>: $@";
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
	my ($u, $uid, $kw, $eml, $res) = @_;
	push @$res, [ $kw, $eml ];
};
$nwr->imap_each($$folder_uri, $imap_slurp_all, my $res = []);
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

	lei_ok qw(q f:qp@example.com -o), $$folder_uri;
	$nwr->imap_each($$folder_uri, $imap_slurp_all, my $res = []);
	is(scalar(@$res), 1, 'got one deduped result') or diag explain($res);
	is_deeply($res->[0]->[1], $plack_qp_eml,
			'lei q wrote expected result');

	lei_ok qw(q f:matz -a -o), $$folder_uri;
	$nwr->imap_each($$folder_uri, $imap_slurp_all, my $aug = []);
	is(scalar(@$aug), 2, '2 results after augment') or diag explain($aug);
	my $exp = $res->[0]->[1]->as_string;
	is(scalar(grep { $_->[1]->as_string eq $exp } @$aug), 1,
			'original remains after augment');
	$exp = eml_load('t/iso-2202-jp.eml')->as_string;
	is(scalar(grep { $_->[1]->as_string eq $exp } @$aug), 1,
			'new result shown after augment');

	lei_ok qw(q s:thisbetternotgiveanyresult -o), $folder_uri->as_string;
	$nwr->imap_each($$folder_uri, $imap_slurp_all, my $empty = []);
	is(scalar(@$empty), 0, 'no results w/o augment');

});

undef $cleanup; # remove temporary folder
done_testing;
