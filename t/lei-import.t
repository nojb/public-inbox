#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
test_lei(sub {
ok(!lei(qw(import -F bogus), 't/plack-qp.eml'), 'fails with bogus format');
like($lei_err, qr/\bbogus unrecognized/, 'gave error message');

lei_ok(qw(q s:boolean), \'search miss before import');
unlike($lei_out, qr/boolean/i, 'no results, yet');
open my $fh, '<', 't/data/0001.patch' or BAIL_OUT $!;
lei_ok([qw(import -F eml -)], undef, { %$lei_opt, 0 => $fh },
	\'import single file from stdin') or diag $lei_err;
close $fh;
lei_ok(qw(q s:boolean), \'search hit after import');
lei_ok(qw(q s:boolean -f mboxrd), \'blob accessible after import');
{
	my $expect = [ eml_load('t/data/0001.patch') ];
	require PublicInbox::MboxReader;
	my @cmp;
	open my $fh, '<', \$lei_out or BAIL_OUT "open :scalar: $!";
	PublicInbox::MboxReader->mboxrd($fh, sub {
		my ($eml) = @_;
		$eml->header_set('Status');
		push @cmp, $eml;
	});
	is_deeply(\@cmp, $expect, 'got expected message in mboxrd');
}
lei_ok(qw(import -F eml), 't/data/message_embed.eml',
	\'import single file by path');

lei_ok(qw(q m:testmessage@example.com));
is($lei_out, "[null]\n", 'no results, yet');
my $oid = '9bf1002c49eb075df47247b74d69bcd555e23422';
my $eml = eml_load('t/utf8.eml');
my $in = 'From x@y Fri Oct  2 00:00:00 1993'."\n".$eml->as_string;
lei_ok([qw(import -F eml -)], undef, { %$lei_opt, 0 => \$in });
lei_ok(qw(q m:testmessage@example.com));
is(json_utf8->decode($lei_out)->[0]->{'blob'}, $oid,
	'got expected OID w/o From');

my $eml_str = <<'';
From: a@b
Message-ID: <x@y>
Status: RO

my $opt = { %$lei_opt, 0 => \$eml_str };
lei_ok([qw(import -F eml -)], undef, $opt,
	\'import single file with keywords from stdin');
lei_ok(qw(q m:x@y));
my $res = json_utf8->decode($lei_out);
is($res->[1], undef, 'only one result');
is($res->[0]->{'m'}, 'x@y', 'got expected message');
is($res->[0]->{kw}, undef, 'Status ignored for eml');
lei_ok(qw(q -f mboxrd m:x@y));
unlike($lei_out, qr/^Status:/, 'no Status: in imported message');
lei_ok('blob', $res->[0]->{blob});
is($lei_out, "From: a\@b\nMessage-ID: <x\@y>\n", 'got blob back');


$eml->header_set('Message-ID', '<v@y>');
$eml->header_set('Status', 'RO');
$in = 'From v@y Fri Oct  2 00:00:00 1993'."\n".$eml->as_string;
lei_ok([qw(import --no-kw -F mboxrd -)], undef, { %$lei_opt, 0 => \$in },
	\'import single file with --no-kw from stdin');
lei(qw(q m:v@y));
$res = json_utf8->decode($lei_out);
is($res->[1], undef, 'only one result');
is($res->[0]->{'m'}, 'v@y', 'got expected message');
is($res->[0]->{kw}, undef, 'no keywords set');

$eml->header_set('Message-ID', '<k@y>');
$in = 'From k@y Fri Oct  2 00:00:00 1993'."\n".$eml->as_string;
lei_ok([qw(import -F mboxrd /dev/fd/0)], undef, { %$lei_opt, 0 => \$in },
	\'import single file with --kw (default) from stdin');
lei(qw(q m:k@y));
$res = json_utf8->decode($lei_out);
is($res->[1], undef, 'only one result');
is($res->[0]->{'m'}, 'k@y', 'got expected message');
is_deeply($res->[0]->{kw}, ['seen'], "`seen' keywords set");

# see t/lei_to_mail.t for "import -F mbox*"
});
done_testing;
