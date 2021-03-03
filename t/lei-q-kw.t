#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
test_lei(sub {
lei_ok(qw(import -F eml t/plack-qp.eml));
my $o = "$ENV{HOME}/dst";
lei_ok(qw(q -o), "maildir:$o", qw(m:qp@example.com));
my @fn = glob("$o/cur/*:2,");
scalar(@fn) == 1 or BAIL_OUT "wrote multiple or zero files: ".explain(\@fn);
rename($fn[0], "$fn[0]S") or BAIL_OUT "rename $!";

lei_ok(qw(q -o), "maildir:$o", qw(m:bogus-noresults@example.com));
ok(!glob("$o/cur/*"), 'last result cleared after augment-import');

lei_ok(qw(q -o), "maildir:$o", qw(m:qp@example.com));
@fn = glob("$o/cur/*:2,S");
is(scalar(@fn), 1, "`seen' flag set on Maildir file");

# ensure --no-import-augment works
my $n = $fn[0];
$n =~ s/,S\z/,RS/;
rename($fn[0], $n) or BAIL_OUT "rename $!";
lei_ok(qw(q --no-import-augment -o), "maildir:$o",
	qw(m:bogus-noresults@example.com));
ok(!glob("$o/cur/*"), '--no-import-augment cleared destination');
lei_ok(qw(q -o), "maildir:$o", qw(m:qp@example.com));
@fn = glob("$o/cur/*:2,S");
is(scalar(@fn), 1, "`seen' flag (but not `replied') set on Maildir file");

# TODO: other destination types
});
done_testing;
