# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
require_mods qw(DBD::SQLite);
my $tmp = tmpdir();
my $eml;
my $cb = sub {
	my ($im, $ibx) = @_;
	$eml //= eml_load 't/utf8.eml';
	for my $i (1..3) {
		$eml->header_set('Message-ID', "<$i\@example.com>");
		my $d = "Thu, 01 Jan 1970 0$i:30:00 +0000";
		$eml->header_set('Date', $d);
		$im->add($eml);
	}
};
my %ibx = map {;
	"v$_" => create_inbox("v$_", version => $_,
			indexlevel => 'basic', tmpdir => "$tmp/v$_", $cb);
} (1, 2);

my $env = { TZ => 'UTC' };
my ($out, $err);
for my $v (sort keys %ibx) {
	my $opt = { -C => $ibx{$v}->{inboxdir}, 1 => \$out, 2 => \$err };

	($out, $err) = ('', '');
	run_script([ qw(-index -vv) ], $env, $opt);
	is($?, 0, 'no error on initial index');

	for my $x (qw(until before)) {
		($out, $err) = ('', '');
		run_script([ qw(-index --reindex -vv),
				"--$x=1970-01-01T02:00:00Z" ], $env, $opt);
		is($?, 0, "no error with --$x");
		like($err, qr! 1/1\b!, "$x only indexed one message");
	}
	for my $x (qw(after since)) {
		($out, $err) = ('', '');
		run_script([ qw(-index --reindex -vv),
				"--$x=1970-01-01T02:00:00Z" ], $env, $opt);
		is($?, 0, "no error with --$x");
		like($err, qr! 2/2\b!, "$x only indexed one message");
	}

	($out, $err) = ('', '');
	run_script([ qw(-index --reindex -vv) ], $env, $opt);
	is($?, 0, 'no error on initial index');

	for my $x (qw(since before after until)) {
		($out, $err) = ('', '');
		run_script([ qw(-index -v), "--$x=1970-01-01T02:00:00Z" ],
			$env, $opt);
		isnt($?, 0, "--$x fails on --reindex");
	}
}

done_testing;
