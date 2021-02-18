#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
use PublicInbox::MboxReader;
use PublicInbox::MdirReader;
use PublicInbox::NetReader;
require_git 2.6;
require_mods(qw(DBD::SQLite Search::Xapian));
my ($tmpdir, $for_destroy) = tmpdir;
my $sock = tcp_server;
my $cmd = [ '-imapd', '-W0', "--stdout=$tmpdir/1", "--stderr=$tmpdir/2" ];
my ($ro_home, $cfg_path) = setup_public_inboxes;
my $env = { PI_CONFIG => $cfg_path };
my $td = start_script($cmd, $env, { 3 => $sock }) or BAIL_OUT("-imapd: $?");
my $host_port = tcp_host_port($sock);
undef $sock;
test_lei({ tmpdir => $tmpdir }, sub {
	my $d = $ENV{HOME};
	my $dig = Digest::SHA->new(256);
	lei_ok('convert', '-o', "mboxrd:$d/foo.mboxrd",
		"imap://$host_port/t.v2.0");
	ok(-f "$d/foo.mboxrd", 'mboxrd created');
	my (@mboxrd, @mboxcl2);
	open my $fh, '<', "$d/foo.mboxrd" or BAIL_OUT $!;
	PublicInbox::MboxReader->mboxrd($fh, sub { push @mboxrd, shift });
	ok(scalar(@mboxrd) > 1, 'got multiple messages');

	lei_ok('convert', '-o', "mboxcl2:$d/cl2", "mboxrd:$d/foo.mboxrd");
	ok(-s "$d/cl2", 'mboxcl2 non-empty') or diag $lei_err;
	open $fh, '<', "$d/cl2" or BAIL_OUT $!;
	PublicInbox::MboxReader->mboxcl2($fh, sub {
		my $eml = shift;
		$eml->header_set($_) for (qw(Content-Length Lines));
		push @mboxcl2, $eml;
	});
	is_deeply(\@mboxcl2, \@mboxrd, 'mboxrd and mboxcl2 have same mail');

	lei_ok('convert', '-o', "$d/md", "mboxrd:$d/foo.mboxrd");
	ok(-d "$d/md", 'Maildir created');
	my @md;
	PublicInbox::MdirReader::maildir_each_eml("$d/md", sub {
		push @md, $_[1];
	});
	is(scalar(@md), scalar(@mboxrd), 'got expected emails in Maildir');
	@md = sort { ${$a->{bdy}} cmp ${$b->{bdy}} } @md;
	@mboxrd = sort { ${$a->{bdy}} cmp ${$b->{bdy}} } @mboxrd;
	my @rd_nostatus = map {
		my $eml = PublicInbox::Eml->new(\($_->as_string));
		$eml->header_set('Status');
		$eml;
	} @mboxrd;
	is_deeply(\@md, \@rd_nostatus, 'Maildir output matches mboxrd');

	my @bar;
	lei_ok('convert', '-o', "mboxrd:$d/bar.mboxrd", "$d/md");
	open $fh, '<', "$d/bar.mboxrd" or BAIL_OUT $!;
	PublicInbox::MboxReader->mboxrd($fh, sub { push @bar, shift });
	@bar = sort { ${$a->{bdy}} cmp ${$b->{bdy}} } @bar;
	is_deeply(\@mboxrd, \@bar,
			'mboxrd round-tripped through Maildir w/ flags');

	open my $in, '<', "$d/foo.mboxrd" or BAIL_OUT;
	my $rdr = { 0 => $in, 1 => \(my $out), 2 => \$lei_err };
	lei_ok([qw(convert --stdin -F mboxrd -o mboxrd:/dev/stdout)],
		undef, $rdr);
	open $fh, '<', "$d/foo.mboxrd" or BAIL_OUT;
	my $exp = do { local $/; <$fh> };
	is($out, $exp, 'stdin => stdout');
});
done_testing;
