#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
use PublicInbox::MboxReader;
use PublicInbox::MdirReader;
use PublicInbox::NetReader;
use PublicInbox::Eml;
use IO::Uncompress::Gunzip;
require_mods(qw(lei -imapd -nntpd Mail::IMAPClient Net::NNTP));
my ($tmpdir, $for_destroy) = tmpdir;
my $sock = tcp_server;
my $cmd = [ '-imapd', '-W0', "--stdout=$tmpdir/i1", "--stderr=$tmpdir/i2" ];
my ($ro_home, $cfg_path) = setup_public_inboxes;
my $env = { PI_CONFIG => $cfg_path };
my $tdi = start_script($cmd, $env, { 3 => $sock }) or BAIL_OUT("-imapd: $?");
my $imap_host_port = tcp_host_port($sock);
$sock = tcp_server;
$cmd = [ '-nntpd', '-W0', "--stdout=$tmpdir/n1", "--stderr=$tmpdir/n2" ];
my $tdn = start_script($cmd, $env, { 3 => $sock }) or BAIL_OUT("-nntpd: $?");
my $nntp_host_port = tcp_host_port($sock);
undef $sock;

test_lei({ tmpdir => $tmpdir }, sub {
	my $d = $ENV{HOME};
	lei_ok('convert', '-o', "mboxrd:$d/foo.mboxrd",
		"imap://$imap_host_port/t.v2.0");
	ok(-f "$d/foo.mboxrd", 'mboxrd created from imap://');

	lei_ok('convert', '-o', "mboxrd:$d/nntp.mboxrd",
		"nntp://$nntp_host_port/t.v2");
	ok(-f "$d/nntp.mboxrd", 'mboxrd created from nntp://');

	my (@mboxrd, @mboxcl2);
	open my $fh, '<', "$d/foo.mboxrd" or BAIL_OUT $!;
	PublicInbox::MboxReader->mboxrd($fh, sub { push @mboxrd, shift });
	ok(scalar(@mboxrd) > 1, 'got multiple messages');

	open $fh, '<', "$d/nntp.mboxrd" or BAIL_OUT $!;
	my $i = 0;
	PublicInbox::MboxReader->mboxrd($fh, sub {
		my ($eml) = @_;
		is($eml->body, $mboxrd[$i]->body, "body matches #$i");
		$i++;
	});

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
	PublicInbox::MdirReader->new->maildir_each_eml("$d/md", sub {
		push @md, $_[2];
	});
	is(scalar(@md), scalar(@mboxrd), 'got expected emails in Maildir') or
		diag $lei_err;
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

	lei_ok qw(convert -F eml -o mboxcl2:/dev/fd/1 t/plack-qp.eml);
	open $fh, '<', \$lei_out or BAIL_OUT;
	@bar = ();
	PublicInbox::MboxReader->mboxcl2($fh, sub {
		my $eml = shift;
		for my $h (qw(Content-Length Lines)) {
			ok(defined($eml->header_raw($h)),
				"$h defined for mboxcl2");
			$eml->header_set($h);
		}
		push @bar, $eml;
	});
	my $qp_eml = eml_load('t/plack-qp.eml');
	$qp_eml->header_set('Status', 'O');
	is_deeply(\@bar, [ $qp_eml ], 'eml => mboxcl2');

	lei_ok qw(convert t/plack-qp.eml -o), "mboxrd:$d/qp.gz";
	open $fh, '<', "$d/qp.gz" or xbail $!;
	ok(-s $fh, 'not empty');
	$fh = IO::Uncompress::Gunzip->new($fh, MultiStream => 1);
	@bar = ();
	PublicInbox::MboxReader->mboxrd($fh, sub { push @bar, shift });
	is_deeply(\@bar, [ $qp_eml ], 'wrote gzipped mboxrd');
	lei_ok qw(convert -o mboxrd:/dev/stdout), "mboxrd:$d/qp.gz";
	open $fh, '<', \$lei_out or xbail;
	@bar = ();
	PublicInbox::MboxReader->mboxrd($fh, sub { push @bar, shift });
	is_deeply(\@bar, [ $qp_eml ], 'readed gzipped mboxrd');

	# Status => Maildir flag => Status round trip
	$lei_out =~ s/^Status: O/Status: RO/sm or xbail "`seen' Status";
	$rdr = { 0 => \($in = $lei_out), %$lei_opt };
	lei_ok([qw(convert -F mboxrd -o), "$d/md2"], undef, $rdr);
	@md = glob("$d/md2/*/*");
	is(scalar(@md), 1, 'one message');
	like($md[0], qr/:2,S\z/, "`seen' flag set in Maildir");
	lei_ok(qw(convert -o mboxrd:/dev/stdout), "$d/md2");
	like($lei_out, qr/^Status: RO/sm, "`seen' flag preserved");
});
done_testing;
