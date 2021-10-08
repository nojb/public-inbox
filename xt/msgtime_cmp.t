#!perl -w
# Copyright (C) 2019-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use Test::More;
use PublicInbox::TestCommon;
use PublicInbox::Eml;
use PublicInbox::Inbox;
use PublicInbox::Git;
use PublicInbox::MsgTime qw(msg_timestamp msg_datestamp);
use POSIX qw(strftime);
require_mods('Date::Parse');
my $git;
my ($inboxdir, $git_dir) = @ENV{qw(GIANT_INBOX_DIR GIANT_GIT_DIR)};
if (defined $inboxdir) {
	my $ibx = { inboxdir => $inboxdir, name => 'name' };
	$git = PublicInbox::Inbox->new($ibx)->git;
} elsif (defined $git_dir) {
	# sometimes just an old epoch is enough, since newer filters are nicer
	$git = PublicInbox::Git->new($git_dir);
} else {
	plan skip_all => "GIANT_INBOX_DIR not set for $0";
}
my @cat = qw(cat-file --buffer --batch-check --batch-all-objects);
if (require_git(2.19, 1)) {
	push @cat, '--unordered';
} else {
	warn "git <2.19, cat-file lacks --unordered, locality suffers\n";
}

# millions of "ok" lines are noise, just show mismatches:
sub quiet_is_deeply ($$$$$) {
	my ($cur, $old, $func, $oid, $hdr) = @_;
	if ((scalar(@$cur) != 2) ||
		(scalar(@$old) == 2 &&
			($old->[0] != $cur->[0]) ||
			($old->[1] != $cur->[1]))) {
		for ($cur, $old) {
			$_->[2] = strftime('%Y-%m-%d %k:%M:%S', gmtime($_->[0]))
		}
		is_deeply($cur, $old, "$func $oid");
		diag('got: ', explain($cur));
		diag('exp: ', explain($old));
		diag $hdr->as_string;
	}
}

sub compare {
	my ($bref, $oid, $type, $size) = @_;
	local $SIG{__WARN__} = sub { diag "$oid: ", @_ };
	my $mime = PublicInbox::Eml->new($$bref);
	my $hdr = $mime->header_obj;
	my @cur = msg_datestamp($hdr);
	my @old = Old::msg_datestamp($hdr);
	quiet_is_deeply(\@cur, \@old, 'datestamp', $oid, $hdr);
	@cur = msg_timestamp($hdr);
	@old = Old::msg_timestamp($hdr);
	quiet_is_deeply(\@cur, \@old, 'timestamp', $oid, $hdr);
}

my $fh = $git->popen(@cat);
while (<$fh>) {
	my ($oid, $type) = split / /;
	next if $type ne 'blob';
	$git->cat_async($oid, \&compare);
}
$git->async_wait_all;
ok(1);
done_testing;

# old date/time-related functions
package Old;
use strict;
use warnings;

sub str2date_zone ($) {
	my ($date) = @_;

	my $ts = Date::Parse::str2time($date);
	return undef unless(defined $ts);

	# off is the time zone offset in seconds from GMT
	my ($ss,$mm,$hh,$day,$month,$year,$off) = Date::Parse::strptime($date);

	# new behavior which wasn't in the original old version:
	if ('commit d857e7dc0d816b635a7ead09c3273f8c2d2434be') {
		# "msgtime: assume +0000 if TZ missing when using Date::Parse"
		$off //= '+0000';
	}

	return undef unless(defined $off);

	# Compute the time zone from offset
	my $sign = ($off < 0) ? '-' : '+';
	my $hour = abs(int($off / 3600));
	my $min  = ($off / 60) % 60;

	# deal with weird offsets like '-0420' properly
	$min = 60 - $min if ($min && $off < 0);

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
		# Y2K problems: 3-digit years
		$d =~ s!([A-Za-z]{3}) ([0-9]{3}) ([0-9]{2}:[0-9]{2}:[0-9]{2})!
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
	my ($hdr) = @_; # PublicInbox::Eml
	my $ret;
	$ret = msg_received_at($hdr) and return time_response($ret);
	$ret = msg_date_only($hdr) and return time_response($ret);
	wantarray ? (time, '+0000') : time;
}

# Favors the Date: header for display and sorting within a thread
sub msg_datestamp ($) {
	my ($hdr) = @_; # PublicInbox::Eml
	my $ret;
	$ret = msg_date_only($hdr) and return time_response($ret);
	$ret = msg_received_at($hdr) and return time_response($ret);
	wantarray ? (time, '+0000') : time;
}

1;
