# Copyright (C) 2017-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use File::Temp qw/tempdir/;
use Email::MIME;
use PublicInbox::Config;
use PublicInbox::WWW;
my @mods = qw(PublicInbox::SearchIdx HTTP::Request::Common Plack::Test
		URI::Escape Plack::Builder);
foreach my $mod (@mods) {
	eval "require $mod";
	plan skip_all => "$mod missing for psgi_search.t" if $@;
}
use_ok $_ foreach @mods;
my $tmpdir = tempdir('pi-psgi-search.XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $git_dir = "$tmpdir/a.git";

is(0, system(qw(git init -q --bare), $git_dir), "git init (main)");
my $rw = PublicInbox::SearchIdx->new($git_dir, 1);
ok($rw, "search indexer created");
my $data = <<'EOF';
Subject: test
Message-Id: <utf8@example>
From: Ævar Arnfjörð Bjarmason <avarab@example>
To: git@vger.kernel.org

EOF

my $num = 0;
# nb. using internal API, fragile!
$rw->begin_txn_lazy;

foreach (reverse split(/\n\n/, $data)) {
	$_ .= "\n";
	my $mime = Email::MIME->new(\$_);
	my $bytes = bytes::length($mime->as_string);
	my $doc_id = $rw->add_message($mime, $bytes, ++$num, 'ignored');
	my $mid = $mime->header('Message-Id');
	ok($doc_id, 'message added: '. $mid);
}

$rw->commit_txn_lazy;

my $cfgpfx = "publicinbox.test";
my $config = PublicInbox::Config->new({
	"$cfgpfx.address" => 'git@vger.kernel.org',
	"$cfgpfx.mainrepo" => $git_dir,
});
my $www = PublicInbox::WWW->new($config);
test_psgi(sub { $www->call(@_) }, sub {
	my ($cb) = @_;
	my $res;
	$res = $cb->(GET('/test/?q=%C3%86var'));
	my $html = $res->content;
	like($html, qr/<title>&#198;var - /, 'HTML escaped in title');
	my @res = ($html =~ m/\?q=(.+var)\b/g);
	ok(scalar(@res), 'saw query strings');
	my %uniq = map { $_ => 1 } @res;
	is(1, scalar keys %uniq, 'all query values identical in HTML');
	is('%C3%86var', (keys %uniq)[0], 'matches original query');
	ok(index($html, 'by &#198;var Arnfj&#246;r&#240; Bjarmason') >= 0,
		"displayed Ævar's name properly in HTML");

	my $warn = [];
	local $SIG{__WARN__} = sub { push @$warn, @_ };
	$res = $cb->(GET('/test/?q=s:test&l=5e'));
	is($res->code, 200, 'successful search result');
	is_deeply([], $warn, 'no warnings from non-numeric comparison');

	$res = $cb->(POST('/test/?q=s:bogus&x=m'));
	is($res->code, 404, 'failed search result gives 404');
	is_deeply([], $warn, 'no warnings');
});

done_testing();

1;
