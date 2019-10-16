# Copyright (C) 2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use Benchmark qw(:all);
use PublicInbox::Inbox;
use PublicInbox::View;
require './t/common.perl';

my $pi_dir = $ENV{GIANT_PI_DIR};
plan skip_all => "GIANT_PI_DIR not defined for $0" unless $pi_dir;

my @cat = qw(cat-file --buffer --batch-check --batch-all-objects);
if (require_git(2.19, 1)) {
	push @cat, '--unordered';
} else {
	warn
"git <2.19, cat-file lacks --unordered, locality suffers\n";
}

use_ok 'Plack::Util';
my $ibx = PublicInbox::Inbox->new({ inboxdir => $pi_dir, name => 'name' });
my $git = $ibx->git;
my $fh = $git->popen(@cat);
my $vec = '';
vec($vec, fileno($fh), 1) = 1;
select($vec, undef, undef, 60) or die "timed out waiting for --batch-check";

my $ctx = {
	env => { HTTP_HOST => 'example.com', 'psgi.url_scheme' => 'https' },
	-inbox => $ibx,
	www => Plack::Util::inline_object(style => sub {''}),
};
my ($str, $mime, $res, $cmt, $type);
my $n = 0;
my $t = timeit(1, sub {
	while (<$fh>) {
		($cmt, $type) = split / /;
		next if $type ne 'blob';
		++$n;
		$str = $git->cat_file($cmt);
		$mime = PublicInbox::MIME->new($str);
		$res = PublicInbox::View::msg_html($ctx, $mime);
		$res = $res->[2];
		while (defined($res->getline)) {}
		$res->close;
	}
});
diag 'msg_html took '.timestr($t)." for $n messages";
ok 1;
done_testing();
