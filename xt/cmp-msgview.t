#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use Test::More;
use Benchmark qw(:all);
use PublicInbox::Inbox;
use PublicInbox::View;
use PublicInbox::TestCommon;
use PublicInbox::Eml;
use Digest::MD5;
require_git(2.19);
require_mods qw(Data::Dumper Email::MIME Plack::Util);
Data::Dumper->import('Dumper');
require PublicInbox::MIME;
my ($tmpdir, $for_destroy) = tmpdir();
my $inboxdir = $ENV{GIANT_INBOX_DIR};
plan skip_all => "GIANT_INBOX_DIR not defined for $0" unless $inboxdir;
my @cat = qw(cat-file --buffer --batch-check --batch-all-objects --unordered);
my $ibx = PublicInbox::Inbox->new({ inboxdir => $inboxdir, name => 'perf' });
my $git = $ibx->git;
my $fh = $git->popen(@cat);
vec(my $vec = '', fileno($fh), 1) = 1;
select($vec, undef, undef, 60) or die "timed out waiting for --batch-check";
my $mime_ctx = {
	env => { HTTP_HOST => 'example.com', 'psgi.url_scheme' => 'https' },
	ibx => $ibx,
	www => Plack::Util::inline_object(style => sub {''}),
	obuf => \(my $mime_buf = ''),
	mhref => '../',
};
my $eml_ctx = { %$mime_ctx, obuf => \(my $eml_buf = '') };
my $n = 0;
my $m = 0;
my $ndiff_html = 0;
my $dig_cls = 'Digest::MD5';
my $digest_attach = sub { # ensure ->body (not ->body_raw) matches
	my ($p, $cmp_arg) = @_;
	my $part = shift @$p;
	my $dig = $cmp_arg->[0] //= $dig_cls->new;
	$dig->add($part->body_raw);
	push @$cmp_arg, join(', ', @$p);
};

my $git_cb = sub {
	my ($bref, $oid) = @_;
	local $SIG{__WARN__} = sub { diag "$inboxdir $oid ", @_ };
	++$m;
	my $mime = PublicInbox::MIME->new($$bref);
	PublicInbox::View::multipart_text_as_html($mime, $mime_ctx);
	my $eml = PublicInbox::Eml->new($$bref);
	PublicInbox::View::multipart_text_as_html($eml, $eml_ctx);
	if ($eml_buf ne $mime_buf) {
		++$ndiff_html;
		open my $fh, '>', "$tmpdir/mime" or die $!;
		print $fh $mime_buf or die $!;
		close $fh or die $!;
		open $fh, '>', "$tmpdir/eml" or die $!;
		print $fh $eml_buf or die $!;
		close $fh or die $!;
		# using `git diff', diff(1) may not be installed
		diag "$inboxdir $oid differs";
		diag xqx([qw(git diff), "$tmpdir/mime", "$tmpdir/eml"]);
	}
	$eml_buf = $mime_buf = '';

	# don't tolerate differences in attachment downloads
	$mime = PublicInbox::MIME->new($$bref);
	$mime->each_part($digest_attach, my $mime_cmp = [], 1);
	$eml = PublicInbox::Eml->new($$bref);
	$eml->each_part($digest_attach, my $eml_cmp = [], 1);
	$mime_cmp->[0] = $mime_cmp->[0]->hexdigest;
	$eml_cmp->[0] = $eml_cmp->[0]->hexdigest;
	# don't have millions of "ok" lines
	if (join("\0", @$eml_cmp) ne join("\0", @$mime_cmp)) {
		diag Dumper([ $oid, eml => $eml_cmp, mime =>$mime_cmp ]);
		is_deeply($eml_cmp, $mime_cmp, "$inboxdir $oid match");
	}
};
my $t = timeit(1, sub {
	while (<$fh>) {
		my ($oid, $type) = split / /;
		next if $type ne 'blob';
		++$n;
		$git->cat_async($oid, $git_cb);
	}
	$git->async_wait_all;
});
is($m, $n, 'rendered all messages');

# we'll tolerate minor differences in HTML rendering
diag "$ndiff_html HTML differences";

done_testing();
