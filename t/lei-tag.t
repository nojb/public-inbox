#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
require_git 2.6;
require_mods(qw(json DBD::SQLite Search::Xapian));
my ($ro_home, $cfg_path) = setup_public_inboxes;
my $check_kw = sub {
	my ($exp, %opt) = @_;
	my $args = $opt{args} // [];
	my $mid = $opt{mid} // 'testmessage@example.com';
	lei_ok('q', "m:$mid", @$args);
	my $res = json_utf8->decode($lei_out);
	is($res->[1], undef, 'only got one result');
	my $msg = $opt{msg} ? " $opt{msg}" : '';
	($exp ? is_deeply($res->[0]->{kw}, $exp, "got @$exp$msg")
		: is($res->[0]->{kw}, undef, "got undef$msg")) or
			diag explain($res);
	if (exists $opt{L}) {
		$exp = $opt{L};
		($exp ? is_deeply($res->[0]->{L}, $exp, "got @$exp$msg")
			: is($res->[0]->{L}, undef, "got undef$msg")) or
				diag explain($res);
	}
};

test_lei(sub {
	lei_ok(qw(ls-label)); is($lei_out, '', 'no labels, yet');
	lei_ok(qw(import t/utf8.eml));
	lei_ok(qw(tag t/utf8.eml +kw:flagged +L:urgent));
	$check_kw->(['flagged'], L => ['urgent']);
	lei_ok(qw(ls-label)); is($lei_out, "urgent\n", 'label found');
	ok(!lei(qw(tag -F eml t/utf8.eml +kw:seeen)), 'bad kw rejected');
	like($lei_err, qr/`seeen' is not one of/, 'got helpful error');

	ok(!lei(qw(tag -F eml t/utf8.eml +k:seen)), 'bad prefix rejected');
	like($lei_err, qr/Unable to handle.*\Q+k:seen\E/, 'bad prefix noted');

	ok(!lei(qw(tag -F eml t/utf8.eml)), 'no keywords');
	like($lei_err, qr/no keywords or labels specified/,
		'lack of kw/L noted');

	my $mb = "$ENV{HOME}/mb";
	my $md = "$ENV{HOME}/md";
	lei_ok(qw(q m:testmessage@example.com -o), "mboxrd:$mb");
	ok(-s $mb, 'wrote mbox result');
	lei_ok(qw(q m:testmessage@example.com -o), $md);
	my @fn = glob("$md/cur/*");
	scalar(@fn) == 1 or xbail $lei_err, 'no mail', \@fn;
	rename($fn[0], "$fn[0]S") or BAIL_OUT "rename $!";
	$check_kw->(['flagged'], msg => 'after bad request');
	lei_ok(qw(tag -F eml t/utf8.eml -kw:flagged));
	$check_kw->(undef, msg => 'keyword cleared');
	lei_ok(qw(tag -F mboxrd +kw:seen), $mb);
	$check_kw->(['seen'], msg => 'mbox Status ignored');
	lei_ok(qw(tag -kw:seen +kw:answered), $md);
	$check_kw->(['answered'], msg => 'Maildir Status ignored');

	open my $in, '<', 't/utf8.eml' or BAIL_OUT $!;
	lei_ok([qw(tag -F eml - +kw:seen +L:nope)],
		undef, { %$lei_opt, 0 => $in });
	$check_kw->(['answered', 'seen'], msg => 'stdin works');
	lei_ok(qw(q L:urgent));
	my $res = json_utf8->decode($lei_out);
	is($res->[0]->{'m'}, 'testmessage@example.com', 'L: query works');
	lei_ok(qw(q kw:seen));
	my $r2 = json_utf8->decode($lei_out);
	is_deeply($r2, $res, 'kw: query works, too') or
		diag explain([$r2, $res]);

	lei_ok(qw(_complete lei tag));
	my %c = map { $_ => 1 } split(/\s+/, $lei_out);
	ok($c{'+L:urgent'} && $c{'-L:urgent'} &&
		$c{'+L:nope'} && $c{'-L:nope'}, 'completed with labels');

	my $mid = 'qp@example.com';
	lei_ok qw(q -f mboxrd --only), "$ro_home/t2", "mid:$mid";
	$in = $lei_out;
	lei_ok [qw(tag -F mboxrd --stdin +kw:seen +L:qp)],
		undef, { %$lei_opt, 0 => \$in };
	$check_kw->(['seen'], L => ['qp'], mid => $mid,
			args => [ '--only', "$ro_home/t2" ],
			msg => 'external-only message');
	lei_ok(qw(ls-label));
	is($lei_out, "nope\nqp\nurgent\n", 'ls-label shows qp');

	lei_ok qw(tag -F eml t/utf8.eml +L:inbox +L:x);
	lei_ok qw(q m:testmessage@example.com);
	$check_kw->([qw(answered seen)], L => [qw(inbox nope urgent x)]);
	lei_ok(qw(ls-label));
	is($lei_out, "inbox\nnope\nqp\nurgent\nx\n", 'ls-label shows qp');

	lei_ok qw(q L:inbox);
	is(json_utf8->decode($lei_out)->[0]->{blob},
		$r2->[0]->{blob}, 'label search works');

	ok(!lei(qw(tag -F eml t/utf8.eml +L:ALLCAPS)), '+L:ALLCAPS fails');
	lei_ok(qw(ls-label));
	is($lei_out, "inbox\nnope\nqp\nurgent\nx\n", 'ls-label unchanged');

	if (0) { # TODO label+kw search w/ externals
		lei_ok(qw(q L:qp), "mid:$mid", '--only', "$ro_home/t2");
	}
});
done_testing;
