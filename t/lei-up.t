#!perl -w
# Copyright all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);
test_lei(sub {
	my ($ro_home, $cfg_path) = setup_public_inboxes;
	my $home = $ENV{HOME};
	my $qp = eml_load('t/plack-qp.eml');
	my $s = $qp->as_string;
	lei_ok [qw(import -q -F eml -)], undef, { 0 => \$s, %$lei_opt };
	lei_ok qw(q z:0.. -f mboxcl2 -o), "$home/a.mbox.gz";
	lei_ok qw(q z:0.. -f mboxcl2 -o), "$home/b.mbox.gz";
	lei_ok qw(q z:0.. -f mboxcl2 -o), "$home/a";
	lei_ok qw(q z:0.. -f mboxcl2 -o), "$home/b";
	my $uc;
	for my $x (qw(a b)) {
		gunzip("$home/$x.mbox.gz" => \$uc, MultiStream => 1) or
				xbail "gunzip $GunzipError";
		ok(index($uc, $qp->body_raw) >= 0,
			"original mail in $x.mbox.gz");
		open my $fh, '<', "$home/$x" or xbail $!;
		$uc = do { local $/; <$fh> } // xbail $!;
		ok(index($uc, $qp->body_raw) >= 0,
			"original mail in uncompressed $x");
	}
	lei_ok qw(ls-search);
	$s = eml_load('t/utf8.eml')->as_string;
	lei_ok [qw(import -q -F eml -)], undef, { 0 => \$s, %$lei_opt };
	lei_ok qw(up --all=local);

	gunzip("$home/a.mbox.gz" => \$uc, MultiStream => 1) or
		 xbail "gunzip $GunzipError";

	open my $fh, '<', "$home/a" or xbail "open: $!";
	my $exp = do { local $/; <$fh> };
	is($uc, $exp, 'compressed and uncompressed match (a.gz)');
	like($exp, qr/testmessage\@example.com/, '2nd message added');

	undef $uc;
	gunzip("$home/b.mbox.gz" => \$uc, MultiStream => 1) or
		 xbail "gunzip $GunzipError";
	is($uc, $exp, 'compressed and uncompressed match (b.gz)');

	open $fh, '<', "$home/b" or xbail "open: $!";
	$uc = do { local $/; <$fh> };
	is($uc, $exp, 'uncompressed both match');

	lei_ok [ qw(up -q), "$home/b", "--mua=touch $home/c" ],
		undef, { run_mode => 0 };
	ok(-f "$home/c", '--mua works with single output');
});

done_testing;
