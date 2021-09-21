#!perl -w
# Copyright all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);
test_lei(sub {
	my ($ro_home, $cfg_path) = setup_public_inboxes;
	my $s = eml_load('t/plack-qp.eml')->as_string;
	lei_ok [qw(import -q -F eml -)], undef, { 0 => \$s, %$lei_opt };
	lei_ok qw(q z:0.. -f mboxcl2 -o), "$ENV{HOME}/a.mbox.gz";
	lei_ok qw(q z:0.. -f mboxcl2 -o), "$ENV{HOME}/b.mbox.gz";
	lei_ok qw(q z:0.. -f mboxcl2 -o), "$ENV{HOME}/a";
	lei_ok qw(q z:0.. -f mboxcl2 -o), "$ENV{HOME}/b";
	lei_ok qw(ls-search);
	$s = eml_load('t/utf8.eml')->as_string;
	lei_ok [qw(import -q -F eml -)], undef, { 0 => \$s, %$lei_opt };
	lei_ok qw(up --all=local);
	open my $fh, "$ENV{HOME}/a.mbox.gz" or xbail "open: $!";
	my $gz = do { local $/; <$fh> };
	my $uc;
	gunzip(\$gz => \$uc, MultiStream => 1) or xbail "gunzip $GunzipError";
	open $fh, "$ENV{HOME}/a" or xbail "open: $!";

	my $exp = do { local $/; <$fh> };
	is($uc, $exp, 'compressed and uncompressed match (a.gz)');
	like($exp, qr/testmessage\@example.com/, '2nd message added');
	open $fh, "$ENV{HOME}/b.mbox.gz" or xbail "open: $!";

	$gz = do { local $/; <$fh> };
	undef $uc;
	gunzip(\$gz => \$uc, MultiStream => 1) or xbail "gunzip $GunzipError";
	is($uc, $exp, 'compressed and uncompressed match (b.gz)');

	open $fh, "$ENV{HOME}/b" or xbail "open: $!";
	$uc = do { local $/; <$fh> };
	is($uc, $exp, 'uncompressed both match');

	lei_ok [ qw(up -q), "$ENV{HOME}/b", "--mua=touch $ENV{HOME}/c" ],
		undef, { run_mode => 0 };
	ok(-f "$ENV{HOME}/c", '--mua works with single output');
});

done_testing;
