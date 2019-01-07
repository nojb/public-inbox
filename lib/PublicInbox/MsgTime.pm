# Copyright (C) 2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Various date/time-related functions
package PublicInbox::MsgTime;
use strict;
use warnings;
use base qw(Exporter);
our @EXPORT_OK = qw(msg_timestamp msg_datestamp);
use Date::Parse qw(str2time strptime);

sub str2date_zone ($) {
	my ($date) = @_;

	my $ts = str2time($date);
	return undef unless(defined $ts);

	# off is the time zone offset in seconds from GMT
	my ($ss,$mm,$hh,$day,$month,$year,$off) = strptime($date);
	return undef unless(defined $off);

	# Compute the time zone from offset
	my $sign = ($off < 0) ? '-' : '+';
	my $hour = abs(int($off / 3600));
	my $min  = ($off / 60) % 60;
	my $zone = sprintf('%s%02d%02d', $sign, $hour, $min);

	# "-1200" is the furthest westermost zone offset,
	# but git fast-import is liberal so we use "-1400"
	if ($zone >= 1400 || $zone <= -1400) {
		warn "bogus TZ offset: $zone, ignoring and assuming +0000\n";
		$zone = '+0000';
	}
	[$ts, $zone];
}

sub time_response ($) {
	my ($ret) = @_;
	wantarray ? @$ret : $ret->[0];
}

sub msg_received_at ($) {
	my ($hdr) = @_; # Email::MIME::Header
	my @recvd = $hdr->header_raw('Received');
	my ($ts);
	foreach my $r (@recvd) {
		$r =~ /\s*(\d+\s+[[:alpha:]]+\s+\d{2,4}\s+
			\d+\D\d+(?:\D\d+)\s+([\+\-]\d+))/sx or next;
		$ts = eval { str2date_zone($1) } and return $ts;
		my $mid = $hdr->header_raw('Message-ID');
		warn "no date in $mid Received: $r\n";
	}
	undef;
}

sub msg_date_only ($) {
	my ($hdr) = @_; # Email::MIME::Header
	my @date = $hdr->header_raw('Date');
	my ($ts);
	foreach my $d (@date) {
		# Y2K problems: 3-digit years
		$d =~ s!([A-Za-z]{3}) (\d{3}) (\d\d:\d\d:\d\d)!
			my $yyyy = $2 + 1900; "$1 $yyyy $3"!e;
		$ts = eval { str2date_zone($d) } and return $ts;
		if ($@) {
			my $mid = $hdr->header_raw('Message-ID');
			warn "bad Date: $d in $mid: $@\n";
		}
	}
	undef;
}

# Favors Received header for sorting globally
sub msg_timestamp ($) {
	my ($hdr) = @_; # Email::MIME::Header
	my $ret;
	$ret = msg_received_at($hdr) and return time_response($ret);
	$ret = msg_date_only($hdr) and return time_response($ret);
	wantarray ? (time, '+0000') : time;
}

# Favors the Date: header for display and sorting within a thread
sub msg_datestamp ($) {
	my ($hdr) = @_; # Email::MIME::Header
	my $ret;
	$ret = msg_date_only($hdr) and return time_response($ret);
	$ret = msg_received_at($hdr) and return time_response($ret);
	wantarray ? (time, '+0000') : time;
}

1;
