#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
require_git 2.6;
require_mods(qw(json DBD::SQLite Search::Xapian));
my $check_kw = sub {
	my ($exp, %opt) = @_;
	my $mid = $opt{mid} // 'testmessage@example.com';
	lei_ok('q', "m:$mid");
	my $res = json_utf8->decode($lei_out);
	is($res->[1], undef, 'only got one result');
	my $msg = $opt{msg} ? " $opt{msg}" : '';
	($exp ? is_deeply($res->[0]->{kw}, $exp, "got @$exp$msg")
		: is($res->[0]->{kw}, undef, "got undef$msg")) or
			diag explain($res);
};

test_lei(sub {
	lei_ok(qw(import -F eml t/utf8.eml));
	lei_ok(qw(mark -F eml t/utf8.eml +kw:flagged));
	$check_kw->(['flagged']);
	ok(!lei(qw(mark -F eml t/utf8.eml +kw:seeen)), 'bad kw rejected');
	like($lei_err, qr/`seeen' is not one of/, 'got helpful error');
	ok(!lei(qw(mark -F eml t/utf8.eml +k:seen)), 'bad prefix rejected');
	ok(!lei(qw(mark -F eml t/utf8.eml)), 'no keywords');
	my $mb = "$ENV{HOME}/mb";
	my $md = "$ENV{HOME}/md";
	lei_ok(qw(q m:testmessage@example.com -o), "mboxrd:$mb");
	ok(-s $mb, 'wrote mbox result');
	lei_ok(qw(q m:testmessage@example.com -o), $md);
	my @fn = glob("$md/cur/*");
	scalar(@fn) == 1 or xbail $lei_err, 'no mail', \@fn;
	rename($fn[0], "$fn[0]S") or BAIL_OUT "rename $!";
	$check_kw->(['flagged'], msg => 'after bad request');
	lei_ok(qw(mark -F eml t/utf8.eml -kw:flagged));
	$check_kw->(undef, msg => 'keyword cleared');
	lei_ok(qw(mark -F mboxrd +kw:seen), $mb);
	$check_kw->(['seen'], msg => 'mbox Status ignored');
	lei_ok(qw(mark -kw:seen +kw:answered), $md);
	$check_kw->(['answered'], msg => 'Maildir Status ignored');

	open my $in, '<', 't/utf8.eml' or BAIL_OUT $!;
	lei_ok([qw(mark -F eml - +kw:seen)], undef, { %$lei_opt, 0 => $in });
	$check_kw->(['answered', 'seen'], msg => 'stdin works');
});
done_testing;
