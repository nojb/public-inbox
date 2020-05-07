# Copyright (C) 2018-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Various date/time-related functions
package PublicInbox::MsgTime;
use strict;
use warnings;
use base qw(Exporter);
our @EXPORT_OK = qw(msg_timestamp msg_datestamp);
use Time::Local qw(timegm);
my @MoY = qw(january february march april may june
		july august september october november december);
my %MoY;
@MoY{@MoY} = (0..11);
@MoY{map { substr($_, 0, 3) } @MoY} = (0..11);

my %OBSOLETE_TZ = ( # RFC2822 4.3 (Obsolete Date and Time)
	EST => '-0500', EDT => '-0400',
	CST => '-0600', CDT => '-0500',
	MST => '-0700', MDT => '-0600',
	PST => '-0800', PDT => '-0700',
	UT => '+0000', GMT => '+0000', Z => '+0000',

	# RFC2822 states:
	#   The 1 character military time zones were defined in a non-standard
	#   way in [RFC822] and are therefore unpredictable in their meaning.
);
my $OBSOLETE_TZ = join('|', keys %OBSOLETE_TZ);

sub str2date_zone ($) {
	my ($date) = @_;
	my ($ts, $zone);

	# RFC822 is most likely for email, but we can tolerate an extra comma
	# or punctuation as long as all the data is there.
	# We'll use '\s' since Unicode spaces won't affect our parsing.
	# SpamAssassin ignores commas and redundant spaces, too.
	if ($date =~ /(?:[A-Za-z]+,?\s+)? # day-of-week
			([0-9]+),?\s+  # dd
			([A-Za-z]+)\s+ # mon
			([0-9]{2,4})\s+ # YYYY or YY (or YYY :P)
			([0-9]+)[:\.] # HH:
				((?:[0-9]{2})|(?:\s?[0-9])) # MM
				(?:[:\.]((?:[0-9]{2})|(?:\s?[0-9])))? # :SS
			\s+	# a TZ offset is required:
				([\+\-])? # TZ sign
				[\+\-]* # I've seen extra "-" e.g. "--500"
				([0-9]+|$OBSOLETE_TZ)(?:\s|$) # TZ offset
			/xo) {
		my ($dd, $m, $yyyy, $hh, $mm, $ss, $sign, $tz) =
					($1, $2, $3, $4, $5, $6, $7, $8);
		# don't accept non-English months
		defined(my $mon = $MoY{lc($m)}) or return;

		if (defined(my $off = $OBSOLETE_TZ{$tz})) {
			$sign = substr($off, 0, 1);
			$tz = substr($off, 1);
		}

		# Y2K problems: 3-digit years, follow RFC2822
		if (length($yyyy) <= 3) {
			$yyyy += 1900;

			# and 2-digit years from '09 (2009) (0..49)
			$yyyy += 100 if $yyyy < 1950;
		}

		$ts = timegm($ss // 0, $mm, $hh, $dd, $mon, $yyyy);

		# 4-digit dates in non-spam from 1900s and 1910s exist in
		# lore archives
		return if $ts < 0;

		# Compute the time offset from [+-]HHMM
		$tz //= 0;
		my ($tz_hh, $tz_mm);
		if (length($tz) == 1) {
			$tz_hh = $tz;
			$tz_mm = 0;
		} elsif (length($tz) == 2) {
			$tz_hh = 0;
			$tz_mm = $tz;
		} else {
			$tz_hh = $tz;
			$tz_hh =~ s/([0-9]{2})\z//;
			$tz_mm = $1;
		}
		while ($tz_mm >= 60) {
			$tz_mm -= 60;
			$tz_hh += 1;
		}
		$sign //= '+';
		my $off = $sign . ($tz_mm * 60 + ($tz_hh * 60 * 60));
		$ts -= $off;
		$sign = '+' if $off == 0;
		$zone = sprintf('%s%02d%02d', $sign, $tz_hh, $tz_mm);

	# Time::Zone and Date::Parse are part of the same distribution,
	# and we need Time::Zone to deal with tz names like "EDT"
	} elsif (eval { require Date::Parse }) {
		$ts = Date::Parse::str2time($date);
		return undef unless(defined $ts);

		# off is the time zone offset in seconds from GMT
		my ($ss,$mm,$hh,$day,$month,$year,$off) =
					Date::Parse::strptime($date);
		return unless defined($year);
		$off //= 0;

		# Compute the time zone from offset
		my $sign = ($off < 0) ? '-' : '+';
		my $hour = abs(int($off / 3600));
		my $min  = ($off / 60) % 60;

		# deal with weird offsets like '-0420' properly
		$min = 60 - $min if ($min && $off < 0);

		$zone = sprintf('%s%02d%02d', $sign, $hour, $min);
	} else {
		warn "Date::Parse missing for non-RFC822 date: $date\n";
		return undef;
	}

	# Note: we've already applied the offset to $ts at this point,
	# but we want to keep "git fsck" happy.
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
	my ($hdr) = @_; # PublicInbox::Eml
	my @recvd = $hdr->header_raw('Received');
	my ($ts);
	foreach my $r (@recvd) {
		$r =~ /\s*([0-9]+\s+[a-zA-Z]+\s+[0-9]{2,4}\s+
			[0-9]+[^0-9][0-9]+(?:[^0-9][0-9]+)
			\s+([\+\-][0-9]+))/sx or next;
		$ts = eval { str2date_zone($1) } and return $ts;
		my $mid = $hdr->header_raw('Message-ID');
		warn "no date in $mid Received: $r\n";
	}
	undef;
}

sub msg_date_only ($) {
	my ($hdr) = @_; # PublicInbox::Eml
	my @date = $hdr->header_raw('Date');
	my ($ts);
	foreach my $d (@date) {
		$ts = eval { str2date_zone($d) } and return $ts;
		if ($@) {
			my $mid = $hdr->header_raw('Message-ID');
			warn "bad Date: $d in $mid: $@\n";
		}
	}
	undef;
}

# Favors Received header for sorting globally
sub msg_timestamp ($;$) {
	my ($hdr, $fallback) = @_; # PublicInbox::Eml
	my $ret;
	$ret = msg_received_at($hdr) and return time_response($ret);
	$ret = msg_date_only($hdr) and return time_response($ret);
	time_response([ $fallback // time, '+0000' ]);
}

# Favors the Date: header for display and sorting within a thread
sub msg_datestamp ($;$) {
	my ($hdr, $fallback) = @_; # PublicInbox::Eml
	my $ret;
	$ret = msg_date_only($hdr) and return time_response($ret);
	$ret = msg_received_at($hdr) and return time_response($ret);
	time_response([ $fallback // time, '+0000' ]);
}

1;
