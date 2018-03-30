# Copyright (C) 2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
package PublicInbox::MsgTime;
use strict;
use warnings;
use base qw(Exporter);
our @EXPORT_OK = qw(msg_timestamp msg_datestamp);
use Date::Parse qw(str2time);
use Time::Zone qw(tz_offset);

sub zone_clamp ($) {
	my ($zone) = @_;
	$zone ||= '+0000';
	# "-1200" is the furthest westermost zone offset,
	# but git fast-import is liberal so we use "-1400"
	if ($zone >= 1400 || $zone <= -1400) {
		warn "bogus TZ offset: $zone, ignoring and assuming +0000\n";
		$zone = '+0000';
	}
	$zone;
}

sub time_response ($) {
	my ($ret) = @_;
	wantarray ? @$ret : $ret->[0];
}

sub msg_received_at ($) {
	my ($hdr) = @_; # Email::MIME::Header
	my @recvd = $hdr->header_raw('Received');
	my ($ts, $zone);
	foreach my $r (@recvd) {
		$zone = undef;
		$r =~ /\s*(\d+\s+[[:alpha:]]+\s+\d{2,4}\s+
			\d+\D\d+(?:\D\d+)\s+([\+\-]\d+))/sx or next;
		$zone = $2;
		$ts = eval { str2time($1) } and last;
		my $mid = $hdr->header_raw('Message-ID');
		warn "no date in $mid Received: $r\n";
	}
	defined $ts ? [ $ts, zone_clamp($zone) ] : undef;
}

sub msg_date_only ($) {
	my ($hdr) = @_; # Email::MIME::Header
	my @date = $hdr->header_raw('Date');
	my ($ts, $zone);
	foreach my $d (@date) {
		$zone = undef;
		# Y2K problems: 3-digit years
		$d =~ s!([A-Za-z]{3}) (\d{3}) (\d\d:\d\d:\d\d)!
			my $yyyy = $2 + 1900; "$1 $yyyy $3"!e;
		$ts = eval { str2time($d) };
		if ($@) {
			my $mid = $hdr->header_raw('Message-ID');
			warn "bad Date: $d in $mid: $@\n";
		} elsif ($d =~ /\s+([\+\-]\d+)\s*\z/) {
			$zone = $1;
		}
	}
	defined $ts ? [ $ts, zone_clamp($zone) ] : undef;
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
