# Copyright (C) 2014-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use PublicInbox::TestCommon;
use PublicInbox::Import;
use_ok 'PublicInbox';
ok(defined(eval('$PublicInbox::VERSION')), 'VERSION defined');
use_ok 'PublicInbox::Config';
my ($tmpdir, $for_destroy) = tmpdir();

{
	PublicInbox::Import::init_bare($tmpdir);
	my $inboxdir = "$tmpdir/new\nline";
	my @cmd = ('git', "--git-dir=$tmpdir",
		qw(config publicinbox.foo.inboxdir), $inboxdir);
	is(xsys(@cmd), 0, "set config");

	my $tmp = PublicInbox::Config->new("$tmpdir/config");

	is($tmp->{'publicinbox.foo.inboxdir'}, $inboxdir,
		'config read correctly');
	is($tmp->{'core.bare'}, 'true', 'init used --bare repo');

	my @warn;
	local $SIG{__WARN__} = sub { push @warn, @_ };
	$tmp = PublicInbox::Config->new("$tmpdir/config");
	is($tmp->lookup_name('foo'), undef, 'reject invalid inboxdir');
	like("@warn", qr/^E:.*must not contain `\\n'/sm,
		'warned about newline');
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
		-httpbackend_limiter => undef,
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
		'url' => [ 'http://example.com/test' ],
		-httpbackend_limiter => undef,
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
$pfx.newsgroup=inbox.test
publicinbox.nntpserver=news.example.com
EOF
	my $cfg = PublicInbox::Config->new(\$str);
	my $ibx = $cfg->lookup_name('test');
	is_deeply($ibx->nntp_url({ www => { pi_cfg => $cfg }}),
		[ 'nntp://news.example.com/inbox.test' ],
		'nntp_url uses global NNTP server');

	$str = <<EOF;
$pfx.address=test\@example.com
$pfx.inboxdir=/path/to/non/existent
$pfx.newsgroup=inbox.test
$pfx.nntpserver=news.alt.example.com
publicinbox.nntpserver=news.example.com
publicinbox.imapserver=imaps://mail.example.com
EOF
	$cfg = PublicInbox::Config->new(\$str);
	$ibx = $cfg->lookup_name('test');
	is_deeply($ibx->nntp_url({ www => { pi_cfg => $cfg }}),
		[ 'nntp://news.alt.example.com/inbox.test' ],
		'nntp_url uses per-inbox NNTP server');
	is_deeply($ibx->imap_url({ www => { pi_cfg => $cfg }}),
		[ 'imaps://mail.example.com/inbox.test' ],
		'nntp_url uses per-inbox NNTP server');
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
	ok(!PublicInbox::Config::valid_foo_name($s), "`$d' name rejected");
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
	ok(PublicInbox::Config::valid_foo_name($s), "`$s' name accepted");
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
	is($cfg->repo_objs($t1)->[0], $cfg->repo_objs($t2)->[0],
		'inboxes share ::Git object');
}

{
	for my $t (qw(TRUE true yes on 1 +1 -1 13 0x1 0x12 0X5)) {
		is(PublicInbox::Config::git_bool($t), 1, "$t is true");
		is(xqx([qw(git -c), "test.val=$t",
			qw(config --bool test.val)]),
			"true\n", "$t matches git-config behavior");
	}
	for my $f (qw(FALSE false no off 0 +0 +000 00 0x00 0X0)) {
		is(PublicInbox::Config::git_bool($f), 0, "$f is false");
		is(xqx([qw(git -c), "test.val=$f",
			qw(config --bool test.val)]),
			"false\n", "$f matches git-config behavior");
	}
	is(PublicInbox::Config::git_bool('bogus'), undef,
		'bogus is undef');
}

SKIP: {
	# XXX wildcard match requires git 2.26+
	require_git('1.8.5', 2) or
		skip 'git 1.8.5+ required for --url-match', 2;
	my $f = "$tmpdir/urlmatch";
	open my $fh, '>', $f or BAIL_OUT $!;
	print $fh <<EOF or BAIL_OUT $!;
[imap "imap://mail.example.com"]
	pollInterval = 9
EOF
	close $fh or BAIL_OUT;
	local $ENV{PI_CONFIG} = $f;
	my $cfg = PublicInbox::Config->new;
	my $url = 'imap://mail.example.com/INBOX';
	is($cfg->urlmatch('imap.pollInterval', $url), 9, 'urlmatch hit');
	is($cfg->urlmatch('imap.idleInterval', $url), undef, 'urlmatch miss');
};


done_testing();
