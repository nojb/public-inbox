# Copyright (C) 2014-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::Config;
use PublicInbox::TestCommon;
my ($tmpdir, $for_destroy) = tmpdir();

{
	is(system(qw(git init -q --bare), $tmpdir), 0, "git init successful");
	my @cmd = ('git', "--git-dir=$tmpdir", qw(config foo.bar), "hi\nhi");
	is(system(@cmd), 0, "set config");

	my $tmp = PublicInbox::Config->new("$tmpdir/config");

	is("hi\nhi", $tmp->{"foo.bar"}, "config read correctly");
	is("true", $tmp->{"core.bare"}, "used --bare repo");
}

{
	my $f = "examples/public-inbox-config";
	ok(-r $f, "$f is readable");

	my $cfg = PublicInbox::Config->new($f);
	is_deeply($cfg->lookup('meta@public-inbox.org'), {
		'inboxdir' => '/home/pi/meta-main.git',
		'address' => [ 'meta@public-inbox.org' ],
		'domain' => 'public-inbox.org',
		'url' => [ 'http://example.com/meta' ],
		-primary_address => 'meta@public-inbox.org',
		'name' => 'meta',
		feedmax => 25,
		-httpbackend_limiter => undef,
		nntpserver => undef,
	}, "lookup matches expected output");

	is($cfg->lookup('blah@example.com'), undef,
		"non-existent lookup returns undef");

	my $test = $cfg->lookup('test@public-inbox.org');
	is_deeply($test, {
		'address' => ['try@public-inbox.org',
		              'sandbox@public-inbox.org',
			      'test@public-inbox.org'],
		-primary_address => 'try@public-inbox.org',
		'inboxdir' => '/home/pi/test-main.git',
		'domain' => 'public-inbox.org',
		'name' => 'test',
		feedmax => 25,
		'url' => [ 'http://example.com/test' ],
		-httpbackend_limiter => undef,
		nntpserver => undef,
	}, "lookup matches expected output for test");
}


{
	my $cfgpfx = "publicinbox.test";
	my @altid = qw(serial:gmane:file=a serial:enamg:file=b);
	my $config = PublicInbox::Config->new(\<<EOF);
$cfgpfx.address=test\@example.com
$cfgpfx.mainrepo=/path/to/non/existent
$cfgpfx.altid=serial:gmane:file=a
$cfgpfx.altid=serial:enamg:file=b
EOF
	my $ibx = $config->lookup_name('test');
	is_deeply($ibx->{altid}, [ @altid ]);

	$config = PublicInbox::Config->new(\<<EOF);
$cfgpfx.address=test\@example.com
$cfgpfx.mainrepo=/path/to/non/existent
EOF
	$ibx = $config->lookup_name('test');
	is($ibx->{inboxdir}, '/path/to/non/existent', 'mainrepo still works');

	$config = PublicInbox::Config->new(\<<EOF);
$cfgpfx.address=test\@example.com
$cfgpfx.inboxdir=/path/to/non/existent
$cfgpfx.mainrepo=/path/to/deprecated
EOF
	$ibx = $config->lookup_name('test');
	is($ibx->{inboxdir}, '/path/to/non/existent',
		'inboxdir takes precedence');
}

{
	my $pfx = "publicinbox.test";
	my $str = <<EOF;
$pfx.address=test\@example.com
$pfx.inboxdir=/path/to/non/existent
publicinbox.nntpserver=news.example.com
EOF
	my $cfg = PublicInbox::Config->new(\$str);
	my $ibx = $cfg->lookup_name('test');
	is($ibx->{nntpserver}, 'news.example.com', 'global NNTP server');

	$str = <<EOF;
$pfx.address=test\@example.com
$pfx.inboxdir=/path/to/non/existent
$pfx.nntpserver=news.alt.example.com
EOF
	$cfg = PublicInbox::Config->new(\$str);
	$ibx = $cfg->lookup_name('test');
	is($ibx->{nntpserver}, 'news.alt.example.com','per-inbox NNTP server');
}

# no obfuscate domains
{
	my $pfx = "publicinbox.test";
	my $pfx2 = "publicinbox.foo";
	my $str = <<EOF;
$pfx.address=test\@example.com
$pfx.inboxdir=/path/to/non/existent
$pfx2.address=foo\@example.com
$pfx2.inboxdir=/path/to/foo
publicinbox.noobfuscate=public-inbox.org \@example.com z\@EXAMPLE.com
$pfx.obfuscate=true
EOF
	my $cfg = PublicInbox::Config->new(\$str);
	my $ibx = $cfg->lookup_name('test');
	my $re = $ibx->{-no_obfuscate_re};
	like('meta@public-inbox.org', $re,
		'public-inbox.org address not to be obfuscated');
	like('t@example.com', $re, 'example.com address not to be obfuscated');
	unlike('t@example.comM', $re, 'example.comM address does not match');
	is_deeply($ibx->{-no_obfuscate}, {
			'test@example.com' => 1,
			'foo@example.com' => 1,
			'z@example.com' => 1,
		}, 'known addresses populated');
}

my @invalid = (
	# git rejects this because it locks refnames, but we don't have
	# this problem with inbox names:
	# 'inbox.lock',

	# git rejects these:
	'', '..', '.', 'stash@{9}', 'inbox.', '^caret', '~tilde',
	'*asterisk', 's p a c e s', ' leading-space', 'trailing-space ',
	'question?', 'colon:', '[square-brace]', "\fformfeed",
	"\0zero", "\bbackspace",

);

my %X = ("\0" => '\\0', "\b" => '\\b', "\f" => '\\f', "'" => "\\'");
my $xre = join('|', keys %X);

for my $s (@invalid) {
	my $d = $s;
	$d =~ s/($xre)/$X{$1}/g;
	ok(!PublicInbox::Config::valid_inbox_name($s), "`$d' name rejected");
}

# obviously-valid examples
my @valid = qw(a a@example a@example.com);

# Rejecting more was considered, but then it dawned on me that
# people may intentionally use inbox names which are not URL-friendly
# to prevent the PSGI interface from displaying them...
# URL-unfriendly
# '<', '>', '%', '#', '?', '&', '(', ')',

# maybe these aren't so bad, they're common in Message-IDs, even:
# '!', '$', '=', '+'
push @valid, qw[bang! ca$h less< more> 1% (parens) &more eql= +plus], '#hash';
for my $s (@valid) {
	ok(PublicInbox::Config::valid_inbox_name($s), "`$s' name accepted");
}

{
	my $f = "$tmpdir/ordered";
	open my $fh, '>', $f or die "open: $!";
	my @expect;
	foreach my $i (0..3) {
		push @expect, "$i";
		print $fh <<"" or die "print: $!";
[publicinbox "$i"]
	inboxdir = /path/to/$i.git
	address = $i\@example.com

	}
	close $fh or die "close: $!";
	my $cfg = PublicInbox::Config->new($f);
	my @result;
	$cfg->each_inbox(sub { push @result, $_[0]->{name} });
	is_deeply(\@result, \@expect);
}

{
	my $pfx1 = "publicinbox.test1";
	my $pfx2 = "publicinbox.test2";
	my $str = <<EOF;
$pfx1.address=test\@example.com
$pfx1.inboxdir=/path/to/non/existent
$pfx2.address=foo\@example.com
$pfx2.inboxdir=/path/to/foo
$pfx1.coderepo=project
$pfx2.coderepo=project
coderepo.project.dir=/path/to/project.git
EOF
	my $cfg = PublicInbox::Config->new(\$str);
	my $t1 = $cfg->lookup_name('test1');
	my $t2 = $cfg->lookup_name('test2');
	is($t1->{-repo_objs}->[0], $t2->{-repo_objs}->[0],
		'inboxes share ::Git object');
}

{
	my $check_git = !!$ENV{CHECK_GIT_BOOL};
	for my $t (qw(TRUE true yes on 1 +1 -1 13 0x1 0x12 0X5)) {
		is(PublicInbox::Config::_git_config_bool($t), 1, "$t is true");
		if ($check_git) {
			is(`git -c test.val=$t config --bool test.val`,
				"true\n", "$t matches git-config behavior");
		}
	}
	for my $f (qw(FALSE false no off 0 +0 +000 00 0x00 0X0)) {
		is(PublicInbox::Config::_git_config_bool($f), 0, "$f is false");
		if ($check_git) {
			is(`git -c test.val=$f config --bool test.val`,
				"false\n", "$f matches git-config behavior");
		}
	}
	is(PublicInbox::Config::_git_config_bool('bogus'), undef,
		'bogus is undef');
}

done_testing();
