#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use PublicInbox::TestCommon;
use Benchmark qw(:all);
use PublicInbox::Inbox;
use PublicInbox::View;

my $inboxdir = $ENV{GIANT_INBOX_DIR};
plan skip_all => "GIANT_INBOX_DIR not defined for $0" unless $inboxdir;

my $obfuscate = $ENV{PI_OBFUSCATE} ? 1 : 0;
diag "obfuscate=$obfuscate\n";

my @cat = qw(cat-file --buffer --batch-check --batch-all-objects);
if (require_git(2.19, 1)) {
	push @cat, '--unordered';
} else {
	warn
"git <2.19, cat-file lacks --unordered, locality suffers\n";
}
require_mods qw(Plack::Util);
use_ok 'Plack::Util';
my $ibx = PublicInbox::Inbox->new({ inboxdir => $inboxdir, name => 'name' ,
				    obfuscate => $obfuscate});
my $git = $ibx->git;
my $fh = $git->popen(@cat);
my $vec = '';
vec($vec, fileno($fh), 1) = 1;
select($vec, undef, undef, 60) or die "timed out waiting for --batch-check";

my $ctx = {
	env => { HTTP_HOST => 'example.com', 'psgi.url_scheme' => 'https' },
	ibx => $ibx,
	www => Plack::Util::inline_object(style => sub {''}),
};
my ($mime, $res, $oid, $type);
my $n = 0;
my $obuf = '';
my $m = 0;

my $cb = sub {
	$mime = PublicInbox::Eml->new(shift);
	PublicInbox::View::multipart_text_as_html($mime, $ctx);
	++$m;
	$obuf = '';
};

my $t = timeit(1, sub {
	$ctx->{obuf} = \$obuf;
	$ctx->{mhref} = '../';
	while (<$fh>) {
		($oid, $type) = split / /;
		next if $type ne 'blob';
		++$n;
		$git->cat_async($oid, $cb);
	}
	$git->async_wait_all;
});
diag 'multipart_text_as_html took '.timestr($t)." for $n <=> $m messages";
is($m, $n, 'rendered all messages');
done_testing();
