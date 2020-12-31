#!perl -w
# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use Test::More;
use PublicInbox::TestCommon;
use List::Util qw(shuffle);
use PublicInbox::Eml;
use Fcntl qw(SEEK_SET);
require_ok 'PublicInbox::MboxReader';
require_ok 'PublicInbox::LeiToMail';
my %raw = (
	hdr_only => "From: header-only\@example.com\n\n",
	small_from => "From: small-from\@example.com\n\nFrom hell\n",
	small => "From: small\@example.com\n\nfrom hell\n",
	big_hdr_only => "From: big-header\@example.com\n" .
		(('A: '.('a' x 72)."\n") x 1000)."\n",
	big_body => "From: big-body\@example.com\n\n".
		(('b: '.('b' x 72)."\n") x 1000) .
		"From hell\n",
	big_all => "From: big-all\@example.com\n".
		(("A: ".('a' x 72)."\n") x 1000). "\n" .
		(("b: ".('b' x 72)."\n") x 1000) .
		"From hell\n",
);

if ($ENV{TEST_EXTRA}) {
	for my $fn (glob('t/*.eml'), glob('t/*/*.{patch,eml}')) {
		$raw{$fn} = eml_load($fn)->as_string;
	}
}

my $reader = PublicInbox::MboxReader->new;
my $check_fmt = sub {
	my $fmt = shift;
	my @order = shuffle(keys %raw);
	my $eml2mbox = PublicInbox::LeiToMail->can("eml2$fmt");
	open my $fh, '+>', undef or BAIL_OUT "open: $!";
	for my $k (@order) {
		my $eml = PublicInbox::Eml->new($raw{$k});
		my $buf = $eml2mbox->($eml);
		print $fh $$buf or BAIL_OUT "print $!";
	}
	seek($fh, 0, SEEK_SET) or BAIL_OUT "seek: $!";
	$reader->$fmt($fh, sub {
		my ($eml) = @_;
		my $cur = shift @order;
		my @cl = $eml->header_raw('Content-Length');
		if ($fmt =~ /\Amboxcl/) {
			is(scalar(@cl), 1, "Content-Length set $fmt $cur");
			my $raw = $eml->body_raw;
			my $adj = 0;
			if ($fmt eq 'mboxcl') {
				my @from = ($raw =~ /^(From )/smg);
				$adj = scalar(@from);
			}
			is(length($raw), $cl[0] - $adj,
				"Content-Length is correct $fmt $cur");
			# clobber for ->as_string comparison below
			$eml->header_set('Content-Length');
		} else {
			is(scalar(@cl), 0, "Content-Length unset $fmt $cur");
		}
		my $orig = PublicInbox::Eml->new($raw{$cur});
		is($eml->as_string, $orig->as_string,
			"read back original $fmt $cur");
	});
};
my @mbox = qw(mboxrd mboxo mboxcl mboxcl2);
for my $fmt (@mbox) { $check_fmt->($fmt) }
s/\n/\r\n/sg for (values %raw);
for my $fmt (@mbox) { $check_fmt->($fmt) }

done_testing;
