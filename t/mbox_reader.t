#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
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
{
	my $eml = PublicInbox::Eml->new($raw{small});
	my $mbox_keywords = PublicInbox::MboxReader->can('mbox_keywords');
	is_deeply($mbox_keywords->($eml), [], 'no keywords');
	$eml->header_set('Status', 'RO');
	is_deeply($mbox_keywords->($eml), ['seen'], 'seen extracted');
	$eml->header_set('X-Status', 'A');
	is_deeply($mbox_keywords->($eml), [qw(answered seen)],
		'seen+answered extracted');
}

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
		$eml->header_set('Status');
		$eml->header_set('Lines');
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

			# special case for t/solve/bare.patch, not sure if we
			# should even handle it...
			if ($cl[0] eq '0' && ${$eml->{hdr}} eq '') {
				delete $eml->{bdy};
			}
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

{
	my $no_blank_eom = <<'EOM';
From x@y Fri Oct  2 00:00:00 1993
a: b

body1
From x@y Fri Oct  2 00:00:00 1993
c: d

body2
EOM
	# chop($no_blank_eom) eq "\n" or BAIL_OUT 'broken LF';
	for my $variant (qw(mboxrd mboxo)) {
		my @x;
		open my $fh, '<', \$no_blank_eom or BAIL_OUT 'PerlIO::scalar';
		$reader->$variant($fh, sub { push @x, shift });
		is_deeply($x[0]->{bdy}, \"body1\n", 'LF preserved in 1st');
		is_deeply($x[1]->{bdy}, \"body2\n", 'no LF added in 2nd');
	}
}

SKIP: {
	use PublicInbox::Spawn qw(popen_rd);
	my $fh = popen_rd([ $^X, '-E', <<'' ]);
say "From x@y Fri Oct  2 00:00:00 1993";
print "a: b\n\n", "x" x 70000, "\n\n";
say "From x@y Fri Oct  2 00:00:00 2010";
print "Final: bit\n\n", "Incomplete\n\n";
exit 1

	my @x;
	eval { $reader->mboxrd($fh, sub { push @x, shift->as_string }) };
	like($@, qr/error closing mbox/, 'detects error reading from pipe');
	is(scalar(@x), 1, 'only saw one message');
	is(scalar(grep(/Final/, @x)), 0, 'no incomplete bit');
}

{
	my $html = <<EOM;
<html><head><title>hi,</title></head><body>how are you</body></html>
EOM
	for my $m (qw(mboxrd mboxcl mboxcl2 mboxo)) {
		my (@w, @x);
		local $SIG{__WARN__} = sub { push @w, @_ };
		open my $fh, '<', \$html or xbail 'PerlIO::scalar';
		PublicInbox::MboxReader->$m($fh, sub {
			push @x, $_[0]->as_string
		});
		if ($m =~ /\Amboxcl/) {
			is_deeply(\@x, [], "messages in invalid $m");
		} else {
			is_deeply(\@x, [ "\n$html" ], "body-only $m");
		}
		is_deeply([grep(!/^W: leftover/, @w)], [],
			"no extra warnings besides leftover ($m)");
	}
}

done_testing;
