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
use PublicInbox::MsgIter;
require_mods(qw(Data::Dumper Email::MIME));
Data::Dumper->import('Dumper');
require PublicInbox::MIME;
require_git(2.19);
my ($tmpdir, $for_destroy) = tmpdir();
my $inboxdir = $ENV{GIANT_INBOX_DIR};
plan skip_all => "GIANT_INBOX_DIR not defined for $0" unless $inboxdir;
my @cat = qw(cat-file --buffer --batch-check --batch-all-objects --unordered);
my $ibx = PublicInbox::Inbox->new({ inboxdir => $inboxdir, name => 'cmp' });
my $git = $ibx->git;
my $fh = $git->popen(@cat);
vec(my $vec = '', fileno($fh), 1) = 1;
select($vec, undef, undef, 60) or die "timed out waiting for --batch-check";
my $n = 0;
my $m = 0;
my $dig_cls = 'Digest::MD5';
sub h ($) {
	s/\s+\z//s; # E::M leaves trailing white space
	s/\s+/ /sg;
	"$_[0]: $_";
}

my $cmp = sub {
	my ($p, $cmp_arg) = @_;
	my $part = shift @$p;
	push @$cmp_arg, '---'.join(', ', @$p).'---';
	my $ct = $part->content_type // 'text/plain';
	$ct =~ s/[ \t]+.*\z//s;
	my ($s, $err);
	eval {
		push @$cmp_arg, map { h 'f' } $part->header('From');
		push @$cmp_arg, map { h 't' } $part->header('To');
		push @$cmp_arg, map { h 'cc' } $part->header('Cc');
		push @$cmp_arg, map { h 'mid' } $part->header('Message-ID');
		push @$cmp_arg, map { h 'refs' } $part->header('References');
		push @$cmp_arg, map { h 'irt' } $part->header('In-Reply-To');
		push @$cmp_arg, map { h 's' } $part->header('Subject');
		push @$cmp_arg, map { h 'cd' }
					$part->header('Content-Description');
		($s, $err) = msg_part_text($part, $ct);
		if (defined $s) {
			$s =~ s/\s+\z//s;
			push @$cmp_arg, "S: ".$s;
		} else {
			$part = $part->body;
			push @$cmp_arg, "T: $ct";
			if ($part =~ /[^\p{XPosixPrint}\s]/s) { # binary
				my $dig = $dig_cls->new;
				$dig->add($part);
				push @$cmp_arg, "M: ".$dig->hexdigest;
				push @$cmp_arg, "B: ".length($part);
			} else {
				$part =~ s/\s+\z//s;
				push @$cmp_arg, "X: ".$part;
			}
		}
	};
	if ($@) {
		$err //= '';
		push @$cmp_arg, "E: $@ ($err)";
	}
};

my $ndiff = 0;
my $git_cb = sub {
	my ($bref, $oid) = @_;
	local $SIG{__WARN__} = sub { diag "$inboxdir $oid ", @_ };
	++$m;
	PublicInbox::MIME->new($$bref)->each_part($cmp, my $m_ctx = [], 1);
	PublicInbox::Eml->new($$bref)->each_part($cmp, my $e_ctx = [], 1);
	if (join("\0", @$e_ctx) ne join("\0", @$m_ctx)) {
		++$ndiff;
		open my $fh, '>', "$tmpdir/mime" or die $!;
		print $fh Dumper($m_ctx) or die $!;
		close $fh or die $!;
		open $fh, '>', "$tmpdir/eml" or die $!;
		print $fh Dumper($e_ctx) or die $!;
		close $fh or die $!;
		diag "$inboxdir $oid differ";
		# using `git diff', diff(1) may not be installed
		diag xqx([qw(git diff), "$tmpdir/mime", "$tmpdir/eml"]);
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
is($m, $n, "$inboxdir rendered all $m <=> $n messages");
is($ndiff, 0, "$inboxdir $ndiff differences");
done_testing();
