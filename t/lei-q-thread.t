#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
require_git 2.6;
require_mods(qw(json DBD::SQLite Search::Xapian));
use PublicInbox::LeiToMail;
my ($ro_home, $cfg_path) = setup_public_inboxes;
test_lei(sub {
	my $eml = eml_load('t/utf8.eml');
	my $buf = PublicInbox::LeiToMail::eml2mboxrd($eml, { kw => ['seen'] });
	lei_ok([qw(import -F mboxrd -)], undef, { 0 => $buf, %$lei_opt });

	lei_ok qw(q -t m:testmessage@example.com);
	my $res = json_utf8->decode($lei_out);
	is_deeply($res->[0]->{kw}, [ 'seen' ], 'q -t sets keywords') or
		diag explain($res);

	$eml = eml_load('t/utf8.eml');
	$eml->header_set('References', $eml->header('Message-ID'));
	$eml->header_set('Message-ID', '<a-reply@miss>');
	$buf = PublicInbox::LeiToMail::eml2mboxrd($eml, { kw => ['draft'] });
	lei_ok([qw(import -F mboxrd -)], undef, { 0 => $buf, %$lei_opt });

	lei_ok([qw(q - -t)], undef,
		{ 0 => \'m:testmessage@example.com', %$lei_opt });
	$res = json_utf8->decode($lei_out);
	is(scalar(@$res), 3, 'got 2 results');
	pop @$res;
	my %m = map { $_->{'m'} => $_ } @$res;
	is_deeply($m{'testmessage@example.com'}->{kw}, ['seen'],
		'flag set in direct hit') or diag explain($res);
	is_deeply($m{'a-reply@miss'}->{kw}, ['draft'],
		'flag set in thread hit') or diag explain($res);

	lei_ok qw(q -t -t m:testmessage@example.com);
	$res = json_utf8->decode($lei_out);
	is(scalar(@$res), 3, 'got 2 results with -t -t');
	pop @$res;
	%m = map { $_->{'m'} => $_ } @$res;
	is_deeply($m{'testmessage@example.com'}->{kw}, ['flagged', 'seen'],
		'flagged set in direct hit') or diag explain($res);
	is_deeply($m{'a-reply@miss'}->{kw}, ['draft'],
		'set in thread hit') or diag explain($res);
	lei_ok qw(q -tt m:testmessage@example.com --only), "$ro_home/t2";
	$res = json_utf8->decode($lei_out);
	is_deeply($res->[0]->{kw}, [ qw(flagged seen) ],
		'flagged set on external with -tt') or diag explain($res);
	lei_ok qw(q -t m:testmessage@example.com --only), "$ro_home/t2";
	$res = json_utf8->decode($lei_out);
	is_deeply($res->[0]->{kw}, [ 'seen' ],
		'flagged not set on external with 1 -t') or diag explain($res);
});
done_testing;
