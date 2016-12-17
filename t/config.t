# Copyright (C) 2014-2015 all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
use strict;
use warnings;
use Test::More;
use PublicInbox::Config;
use File::Temp qw/tempdir/;
my $tmpdir = tempdir('pi-config-XXXXXX', TMPDIR => 1, CLEANUP => 1);

{
	is(system(qw(git init -q --bare), $tmpdir), 0, "git init successful");
	my @cmd = ('git', "--git-dir=$tmpdir", qw(config foo.bar hihi));
	is(system(@cmd), 0, "set config");

	my $tmp = PublicInbox::Config->new("$tmpdir/config");

	is("hihi", $tmp->{"foo.bar"}, "config read correctly");
	is("true", $tmp->{"core.bare"}, "used --bare repo");
}

{
	my $f = "examples/public-inbox-config";
	ok(-r $f, "$f is readable");

	my $cfg = PublicInbox::Config->new($f);
	is_deeply($cfg->lookup('meta@public-inbox.org'), {
		'mainrepo' => '/home/pi/meta-main.git',
		'address' => 'meta@public-inbox.org',
		'domain' => 'public-inbox.org',
		'url' => 'http://example.com/meta',
		-primary_address => 'meta@public-inbox.org',
		'name' => 'meta',
		feedmax => 25,
		-pi_config => $cfg,
	}, "lookup matches expected output");

	is($cfg->lookup('blah@example.com'), undef,
		"non-existent lookup returns undef");

	my $test = $cfg->lookup('test@public-inbox.org');
	is_deeply($test, {
		'address' => ['try@public-inbox.org',
		              'sandbox@public-inbox.org',
			      'test@public-inbox.org'],
		-primary_address => 'try@public-inbox.org',
		'mainrepo' => '/home/pi/test-main.git',
		'domain' => 'public-inbox.org',
		'name' => 'test',
		feedmax => 25,
		'url' => 'http://example.com/test',
		-pi_config => $cfg,
	}, "lookup matches expected output for test");
}


{
	my $cfgpfx = "publicinbox.test";
	my @altid = qw(serial:gmane:file=a serial:enamg:file=b);
	my $config = PublicInbox::Config->new({
		"$cfgpfx.address" => 'test@example.com',
		"$cfgpfx.mainrepo" => '/path/to/non/existent',
		"$cfgpfx.altid" => [ @altid ],
	});
	my $ibx = $config->lookup_name('test');
	is_deeply($ibx->{altid}, [ @altid ]);
}

done_testing();
