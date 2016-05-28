# Copyright (C) 2015 all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
use strict;
use warnings;
use Test::More;
use Data::Dumper;

foreach my $mod (qw(DBD::SQLite Search::Xapian Danga::Socket)) {
	eval "require $mod";
	plan skip_all => "$mod missing for nntp.t" if $@;
}

use_ok 'PublicInbox::NNTP';
use_ok 'PublicInbox::Inbox';

{
	sub quote_str {
		my (undef, $s) = split(/ = /, Dumper($_[0]), 2);
		$s =~ s/;\n//;
		$s;
	}

	sub wm_prepare {
		my ($wm) = @_;
		my $orig = qq{'$wm'};
		PublicInbox::NNTP::wildmat2re($_[0]);
		my $new = quote_str($_[0]);
		($orig, $new);
	}

	sub wildmat_like {
		my ($str, $wm) = @_;
		my ($orig, $new) = wm_prepare($wm);
		like($str, $wm, "$orig matches '$str' using $new");
	}

	sub wildmat_unlike {
		my ($str, $wm, $check_ex) = @_;
		if ($check_ex) {
			use re 'eval';
			my $re = qr/$wm/;
			like($str, $re, "normal re with $wm matches, but ...");
		}
		my ($orig, $new) = wm_prepare($wm);
		unlike($str, $wm, "$orig does not match '$str' using $new");
	}

	wildmat_like('[foo]', '[\[foo\]]');
	wildmat_like('any', '*');
	wildmat_unlike('bar.foo.bar', 'foo.*');

	# no code execution
	wildmat_unlike('HI', '(?{"HI"})', 1);
	wildmat_unlike('HI', '[(?{"HI"})]', 1);
}

{
	sub ngpat_like {
		my ($str, $pat) = @_;
		my $orig = $pat;
		PublicInbox::NNTP::ngpat2re($pat);
		like($str, $pat, "'$orig' matches '$str' using $pat");
	}

	ngpat_like('any', '*');
	ngpat_like('a.s.r', 'a.t,a.s.r');
	ngpat_like('a.s.r', 'a.t,a.s.*');
}

{
	use POSIX qw(strftime);
	sub time_roundtrip {
		my ($date, $time, $gmt) = @_;
		my $m = join(' ', @_);
		my $ts = PublicInbox::NNTP::parse_time(@_);
		my @t = gmtime($ts);
		my ($d, $t);
		if (length($date) == 8) {
			($d, $t) = split(' ', strftime('%Y%m%d %H%M%S', @t));
		} else {
			($d, $t) = split(' ', strftime('%g%m%d %H%M%S', @t));
		}
		is_deeply([$d, $t], [$date, $time], "roundtripped: $m");
		$ts;
	}
	my $x1 = time_roundtrip(qw(20141109 060606 GMT));
	my $x2 = time_roundtrip(qw(141109 060606 GMT));
	my $x3 = time_roundtrip(qw(930724 060606 GMT));

	SKIP: {
		skip('YYMMDD test needs updating', 2) if (time > 0x7fffffff);
		# our world probably ends in 2038, but if not we'll try to
		# remember to update the test then
		is($x1, $x2, 'YYYYMMDD and YYMMDD parse identically');
		is(strftime('%Y', gmtime($x3)), '1993', '930724 was in 1993');
	}
}

{ # test setting NNTP headers in HEAD and ARTICLE requests
	require Email::MIME;
	my $u = 'https://example.com/a/';
	my $ng = PublicInbox::Inbox->new({ name => 'test',
					mainrepo => 'test.git',
					address => 'a@example.com',
					-primary_address => 'a@example.com',
					newsgroup => 'test',
					domain => 'example.com',
					url => '//example.com/a'});
	is($ng->base_url, $u, 'URL expanded');
	my $mid = 'a@b';
	my $mime = Email::MIME->new("Message-ID: <$mid>\r\n\r\n");
	PublicInbox::NNTP::set_nntp_headers($mime->header_obj, $ng, 1, $mid);
	is_deeply([ $mime->header('Message-ID') ], [ "<$mid>" ],
		'Message-ID unchanged');
	is_deeply([ $mime->header('Archived-At') ], [ "<${u}a%40b/>" ],
		'Archived-At: set');
	is_deeply([ $mime->header('List-Archive') ], [ "<$u>" ],
		'List-Archive: set');
	is_deeply([ $mime->header('List-Post') ], [ '<mailto:a@example.com>' ],
		'List-Post: set');
	is_deeply([ $mime->header('Newsgroups') ], [ 'test' ],
		'Newsgroups: set');
	is_deeply([ $mime->header('Xref') ], [ 'example.com test:1' ],
		'Xref: set');

	$ng->{-base_url} = 'http://mirror.example.com/m/';
	PublicInbox::NNTP::set_nntp_headers($mime->header_obj, $ng, 2, $mid);
	is_deeply([ $mime->header('Message-ID') ], [ "<$mid>" ],
		'Message-ID unchanged');
	is_deeply([ $mime->header('Archived-At') ],
		[ "<${u}a%40b/>", '<http://mirror.example.com/m/a%40b/>' ],
		'Archived-At: appended');
	is_deeply([ $mime->header('Xref') ], [ 'example.com test:2' ],
		'Old Xref: clobbered');
}

done_testing();
