#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
use File::Path qw(rmtree);
use PublicInbox::Spawn qw(which);

# this only tests the basic help/config/init/completion bits of lei;
# actual functionality is tested in other t/lei-*.t tests
my $curl = which('curl');
my $home;
my $home_trash = [];
my $cleanup = sub { rmtree([@$home_trash, @_]) };

my $test_help = sub {
	ok(!$lei->(), 'no args fails');
	is($? >> 8, 1, '$? is 1');
	is($lei_out, '', 'nothing in stdout');
	like($lei_err, qr/^usage:/sm, 'usage in stderr');

	for my $arg (['-h'], ['--help'], ['help'], [qw(daemon-pid --help)]) {
		ok($lei->($arg), "lei @$arg");
		like($lei_out, qr/^usage:/sm, "usage in stdout (@$arg)");
		is($lei_err, '', "nothing in stderr (@$arg)");
	}

	for my $arg ([''], ['--halp'], ['halp'], [qw(daemon-pid --halp)]) {
		ok(!$lei->($arg), "lei @$arg");
		is($? >> 8, 1, '$? set correctly');
		isnt($lei_err, '', 'something in stderr');
		is($lei_out, '', 'nothing in stdout');
	}
	ok($lei->(qw(init -h)), 'init -h');
	like($lei_out, qr! \Q$home\E/\.local/share/lei/store\b!,
		'actual path shown in init -h');
	ok($lei->(qw(init -h), { XDG_DATA_HOME => '/XDH' }),
		'init with XDG_DATA_HOME');
	like($lei_out, qr! /XDH/lei/store\b!, 'XDG_DATA_HOME in init -h');
	is($lei_err, '', 'no errors from init -h');

	ok($lei->(qw(config -h)), 'config-h');
	like($lei_out, qr! \Q$home\E/\.config/lei/config\b!,
		'actual path shown in config -h');
	ok($lei->(qw(config -h), { XDG_CONFIG_HOME => '/XDC' }),
		'config with XDG_CONFIG_HOME');
	like($lei_out, qr! /XDC/lei/config\b!, 'XDG_CONFIG_HOME in config -h');
	is($lei_err, '', 'no errors from config -h');
};

my $ok_err_info = sub {
	my ($msg) = @_;
	is(grep(!/^I:/, split(/^/, $lei_err)), 0, $msg) or
		diag "$msg: err=$lei_err";
};

my $test_init = sub {
	$cleanup->();
	ok($lei->('init'), 'init w/o args');
	$ok_err_info->('after init w/o args');
	ok($lei->('init'), 'idempotent init w/o args');
	$ok_err_info->('after idempotent init w/o args');

	ok(!$lei->('init', "$home/x"), 'init conflict');
	is(grep(/^E:/, split(/^/, $lei_err)), 1, 'got error on conflict');
	ok(!-e "$home/x", 'nothing created on conflict');
	$cleanup->();

	ok($lei->('init', "$home/x"), 'init conflict resolved');
	$ok_err_info->('init w/ arg');
	ok($lei->('init', "$home/x"), 'init idempotent w/ path');
	$ok_err_info->('init idempotent w/ arg');
	ok(-d "$home/x", 'created dir');
	$cleanup->("$home/x");

	ok(!$lei->('init', "$home/x", "$home/2"), 'too many args fails');
	like($lei_err, qr/too many/, 'noted excessive');
	ok(!-e "$home/x", 'x not created on excessive');
	for my $d (@$home_trash) {
		my $base = (split(m!/!, $d))[-1];
		ok(!-d $d, "$base not created");
	}
	is($lei_out, '', 'nothing in stdout on init failure');
};

my $test_config = sub {
	$cleanup->();
	ok($lei->(qw(config a.b c)), 'config set var');
	is($lei_out.$lei_err, '', 'no output on var set');
	ok($lei->(qw(config -l)), 'config -l');
	is($lei_err, '', 'no errors on listing');
	is($lei_out, "a.b=c\n", 'got expected output');
	ok(!$lei->(qw(config -f), "$home/.config/f", qw(x.y z)),
			'config set var with -f fails');
	like($lei_err, qr/not supported/, 'not supported noted');
	ok(!-f "$home/config/f", 'no file created');
};

my $test_completion = sub {
	ok($lei->(qw(_complete lei)), 'no errors on complete');
	my %out = map { $_ => 1 } split(/\s+/s, $lei_out);
	ok($out{'q'}, "`lei q' offered as completion");
	ok($out{'add-external'}, "`lei add-external' offered as completion");

	ok($lei->(qw(_complete lei q)), 'complete q (no args)');
	%out = map { $_ => 1 } split(/\s+/s, $lei_out);
	for my $sw (qw(-f --format -o --output --mfolder --augment -a
			--mua --no-local --local --verbose -v
			--save-as --no-remote --remote --torsocks
			--reverse -r )) {
		ok($out{$sw}, "$sw offered as `lei q' completion");
	}

	ok($lei->(qw(_complete lei q --form)), 'complete q --format');
	is($lei_out, "--format\n", 'complete lei q --format');
	for my $sw (qw(-f --format)) {
		ok($lei->(qw(_complete lei q), $sw), "complete q $sw ARG");
		%out = map { $_ => 1 } split(/\s+/s, $lei_out);
		for my $f (qw(mboxrd mboxcl2 mboxcl mboxo json jsonl
				concatjson maildir)) {
			ok($out{$f}, "got $sw $f as output format");
		}
	}
	ok($lei->(qw(_complete lei import)), 'complete import');
	%out = map { $_ => 1 } split(/\s+/s, $lei_out);
	for my $sw (qw(--flags --no-flags --no-kw --kw --no-keywords
			--keywords)) {
		ok($out{$sw}, "$sw offered as `lei import' completion");
	}
};

my $test_fail = sub {
SKIP: {
	skip 'no curl', 3 unless which('curl');
	$lei->(qw(q --only http://127.0.0.1:99999/bogus/ t:m));
	is($? >> 8, 3, 'got curl exit for bogus URL');
	$lei->(qw(q --only http://127.0.0.1:99999/bogus/ t:m -o), "$home/junk");
	is($? >> 8, 3, 'got curl exit for bogus URL with Maildir');
	is($lei_out, '', 'no output');
}; # /SKIP
};

test_lei(sub {
	$home = $ENV{HOME};
	$home_trash = [ "$home/.local", "$home/.config", "$home/junk" ];
	$test_help->();
	$test_config->();
	$test_init->();
	$test_completion->();
	$test_fail->();
});

done_testing;
