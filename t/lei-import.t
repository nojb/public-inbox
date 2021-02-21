#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
test_lei(sub {
ok(!lei(qw(import -f bogus), 't/plack-qp.eml'), 'fails with bogus format');
like($lei_err, qr/\bbogus unrecognized/, 'gave error message');

lei_ok(qw(q s:boolean), \'search miss before import');
unlike($lei_out, qr/boolean/i, 'no results, yet');
open my $fh, '<', 't/data/0001.patch' or BAIL_OUT $!;
lei_ok([qw(import -f eml -)], undef, { %$lei_opt, 0 => $fh },
	\'import single file from stdin') or diag $lei_err;
close $fh;
lei_ok(qw(q s:boolean), \'search hit after import');
lei_ok(qw(import -f eml), 't/data/message_embed.eml',
	\'import single file by path');

my $str = <<'';
From: a@b
Message-ID: <x@y>
Status: RO

my $opt = { %$lei_opt, 0 => \$str };
lei_ok([qw(import -f eml -)], undef, $opt,
	\'import single file with keywords from stdin');
lei_ok(qw(q m:x@y));
my $res = json_utf8->decode($lei_out);
is($res->[1], undef, 'only one result');
is_deeply($res->[0]->{kw}, ['seen'], "message `seen' keyword set");

$str =~ tr/x/v/; # v@y
lei_ok([qw(import --no-kw -f eml -)], undef, $opt,
	\'import single file with --no-kw from stdin');
lei(qw(q m:v@y));
$res = json_utf8->decode($lei_out);
is($res->[1], undef, 'only one result');
is_deeply($res->[0]->{kw}, [], 'no keywords set');

# see t/lei_to_mail.t for "import -f mbox*"
});
done_testing;
