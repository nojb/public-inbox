# Copyright (C) 2013-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# For the -mda script (mail delivery agent)
package PublicInbox::MDA;
use strict;
use warnings;
use Email::Simple;
use Date::Parse qw(strptime);
use constant MAX_SIZE => 1024 * 500; # same as spamc default, should be tunable
use constant MAX_MID_SIZE => 244; # max term size - 1 in Xapian

our @BAD_HEADERS = (
	# postfix
	qw(delivered-to x-original-to), # prevent training loops

	# The rest are taken from Mailman 2.1.15:
	# could contain passwords:
	qw(approved approve x-approved x-approve urgent),
	# could be used phishing:
	qw(return-receipt-to disposition-notification-to x-confirm-reading-to),
	# Pegasus mail:
	qw(x-pmrqc)
);

# drop plus addressing for matching
sub __drop_plus {
	my ($str_addr) = @_;
	$str_addr =~ s/\+.*\@/\@/;
	$str_addr;
}

# do not allow Bcc, only Cc and To if recipient is set
sub precheck {
	my ($klass, $simple, $address) = @_;
	my @mid = $simple->header('Message-ID');
	return 0 if scalar(@mid) != 1;
	my $mid = $mid[0];
	return 0 if (length($mid) > MAX_MID_SIZE);
	return 0 unless usable_str(length('<m@h>'), $mid) && $mid =~ /\@/;
	return 0 unless usable_str(length('u@h'), $simple->header("From"));
	return 0 unless usable_str(length(':o'), $simple->header("Subject"));
	return 0 unless usable_date($simple->header("Date"));
	return 0 if length($simple->as_string) > MAX_SIZE;
	alias_specified($simple, $address);
}

sub usable_str {
	my ($len, $str) = @_;
	defined($str) && length($str) >= $len;
}

sub usable_date {
	my @t = eval { strptime(@_) };
	scalar @t;
}

sub alias_specified {
	my ($simple, $address) = @_;

	my @address = ref($address) eq 'ARRAY' ? @$address : ($address);
	my %ok = map {
		lc(__drop_plus($_)) => 1;
	} @address;

	foreach my $line ($simple->header('Cc'), $simple->header('To')) {
		my @addrs = ($line =~ /([^,<\s]+\@[^,>\s]+)/g);
		foreach my $addr (@addrs) {
			if ($ok{lc(__drop_plus($addr))}) {
				return 1;
			}
		}
	}
	return 0;
}

sub set_list_headers {
	my ($class, $simple, $dst) = @_;
	unless (defined $simple->header('List-Id')) {
		my $pa = $dst->{-primary_address};
		$pa =~ tr/@/./; # RFC2919
		$simple->header_set("List-Id", "<$pa>");
	}

	$simple->header_set($_) foreach @BAD_HEADERS;
}

1;
