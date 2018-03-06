# Copyright (C) 2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
package PublicInbox::MsgTime;
use strict;
use warnings;
use base qw(Exporter);
our @EXPORT_OK = qw(msg_timestamp);
use Date::Parse qw(str2time);
use Time::Zone qw(tz_offset);

sub msg_timestamp ($) {
	my ($hdr) = @_; # Email::MIME::Header
	my ($ts, $zone);
	my $mid;
	my @recvd = $hdr->header_raw('Received');
	foreach my $r (@recvd) {
		$zone = undef;
		$r =~ /\s*(\d+\s+[[:alpha:]]+\s+\d{2,4}\s+
			\d+\D\d+(?:\D\d+)\s+([\+\-]\d+))/sx or next;
		$zone = $2;
		$ts = eval { str2time($1) } and last;
		$mid ||= $hdr->header_raw('Message-ID');
		warn "no date in $mid Received: $r\n";
	}
	unless (defined $ts) {
		my @date = $hdr->header_raw('Date');
		foreach my $d (@date) {
			$zone = undef;
			$ts = eval { str2time($d) };
			if ($@) {
				$mid ||= $hdr->header_raw('Message-ID');
				warn "bad Date: $d in $mid: $@\n";
			} elsif ($d =~ /\s+([\+\-]\d+)\s*\z/) {
				$zone = $1;
			}
		}
	}
	$ts = time unless defined $ts;
	return $ts unless wantarray;

	$zone ||= '+0000';
	# "-1200" is the furthest westermost zone offset,
	# but git fast-import is liberal so we use "-1400"
	if ($zone >= 1400 || $zone <= -1400) {
		warn "bogus TZ offset: $zone, ignoring and assuming +0000\n";
		$zone = '+0000';
	}
	($ts, $zone);
}

1;
