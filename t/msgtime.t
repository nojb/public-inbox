# Copyright (C) 2016-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::MIME;
use PublicInbox::MsgTime;
our $received_date = 'Mon, 22 Jan 2007 13:16:24 -0500';
sub datestamp ($) {
	my ($date) = @_;
	local $SIG{__WARN__} = sub {};  # Suppress warnings
	my $mime = PublicInbox::MIME->create(
		header => [
			From => 'a@example.com',
			To => 'b@example.com',
			'Content-Type' => 'text/plain',
			Subject => 'this is a subject',
			'Message-ID' => '<a@example.com>',
			Date => $date,
			'Received' => <<EOF,
(majordomo\@vger.kernel.org) by vger.kernel.org via listexpand
\tid S932173AbXAVSQY (ORCPT <rfc822;w\@1wt.eu>);
\t$received_date
EOF
		],
		body => "hello world\n",
	    );
	my @ts = PublicInbox::MsgTime::msg_datestamp($mime->header_obj);
	return \@ts;
}

sub timestamp ($) {
	my ($received) = @_;
	local $SIG{__WARN__} = sub {};  # Suppress warnings
	my $mime = PublicInbox::MIME->create(
		header => [
			From => 'a@example.com',
			To => 'b@example.com',
			'Content-Type' => 'text/plain',
			Subject => 'this is a subject',
			'Message-ID' => '<a@example.com>',
			Date => 'Fri, 02 Oct 1993 00:00:00 +0000',
			'Received' => '(majordomo@vger.kernel.org) by vger.kernel.org via listexpand\n\tid S932173AbXAVSQY (ORCPT <rfc822;w@1wt.eu>);\n\t' . $received,
		],
		body => "hello world\n",
	    );
	my @ts = PublicInbox::MsgTime::msg_timestamp($mime->header_obj);
	return \@ts;
}

# Verify that the parser sucks up the timezone for dates
for (my $min = -1440; $min <= 1440; $min += 30) {
	my $sign = ($min < 0) ? '-': '+';
	my $h = abs(int($min / 60));
	my $m = $min % 60;

	my $ts_expect = 749520000 - ($min * 60);
	my $tz_expect = sprintf('%s%02d%02d', $sign, $h, $m);
	if ($tz_expect >= 1400 || $tz_expect <= -1400) {
		$tz_expect = '+0000';
	}
	my $date = sprintf("Fri, 02 Oct 1993 00:00:00 %s%02d%02d",
			   $sign, $h, $m);
	my $result = datestamp($date);
	is_deeply($result, [ $ts_expect, $tz_expect ], $date);
}

# Verify that the parser sucks up the timezone and for received timestamps
for (my $min = -1440; $min <= 1440; $min += 30) {
	my $sign = ($min < 0) ? '-' : '+';
	my $h = abs(int($min / 60));
	my $m = $min %60;

	my $ts_expect = 1169471784 - ($min * 60);
	my $tz_expect = sprintf('%s%02d%02d', $sign, $h, $m);
	if ($tz_expect >= 1400 || $tz_expect <= -1400) {
		$tz_expect = '+0000';
	}
	my $received = sprintf('Mon, 22 Jan 2007 13:16:24 %s%02d%02d',
			       $sign, $h, $m);
	is_deeply(timestamp($received), [ $ts_expect, $tz_expect ],
		$received);
}

sub is_datestamp ($$) {
	my ($date, $expect) = @_;
	is_deeply(datestamp($date), $expect, $date);
}
is_datestamp('Wed, 13 Dec 2006 10:26:38 +1', [1166001998, '+0100']);
is_datestamp('Fri, 3 Feb 2006 18:11:22 -00', [1138990282, '+0000']);
is_datestamp('Thursday, 20 Feb 2003 01:14:34 +000', [1045703674, '+0000']);
is_datestamp('Fri, 28 Jun 2002 12:54:40 -700', [1025294080, '-0700']);
is_datestamp('Sat, 12 Jan 2002 12:52:57 -200', [1010847177, '-0200']);
is_datestamp('Mon, 05 Nov 2001 10:36:16 -800', [1004985376, '-0800']);
is_datestamp('Tue, 3 Jun 2003 8:58:23 --500', [1054648703, '-0500']);
is_datestamp('Thu, 18 May 100 10:40:43 +0200 (MET DST)', [958639243, '+0200']);
is_datestamp('Thu, 18 May 2000 10:40:43 +0200', [958639243, '+0200']);
is_datestamp('Tue, 27 Feb 2007 16:23:25 -0060', [1172597005, '-0100']);
is_datestamp('Wed, 20 Dec 2006 05:32:58 -0420', [1166608378, '-0420']);
is_datestamp('Wed, 20 Dec 2006 05:32:58 +0420', [1166577178, '+0420']);
is_datestamp('Thu, 14 Dec 2006 00:20:24 +0480', [1166036424, '+0520']);
is_datestamp('Thu, 14 Dec 2006 00:20:24 -0480', [1166074824, '-0520']);
is_datestamp('Mon, 14 Apr 2014 07:59:01 -0007', [1397462761, '-0007']);

# obsolete formats described in RFC2822
for (qw(UT GMT Z)) {
	is_datestamp('Fri, 02 Oct 1993 00:00:00 '.$_, [ 749520000, '+0000']);
}
is_datestamp('Fri, 02 Oct 1993 00:00:00 EDT', [ 749534400, '-0400']);

# fallback to Received: header if Date: is out-of-range:
is_datestamp('Fri, 1 Jan 1904 10:12:31 +0100',
	PublicInbox::MsgTime::str2date_zone($received_date));
is_datestamp('Fri, 9 Mar 71685 18:45:56 +0000', # Y10K is not my problem :P
	PublicInbox::MsgTime::str2date_zone($received_date));

done_testing();
