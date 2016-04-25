# Copyright (C) 2013-2015 all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
#
# For the -mda script (mail delivery agent)
package PublicInbox::MDA;
use strict;
use warnings;
use Email::Simple;
use Email::Address;
use Date::Parse qw(strptime);
use constant MAX_SIZE => 1024 * 500; # same as spamc default, should be tunable
use constant MAX_MID_SIZE => 244; # max term size - 1 in Xapian
use constant cmd => qw/ssoma-mda -1/;

# drop plus addressing for matching
sub __drop_plus {
	my ($str_addr) = @_;
	$str_addr =~ s/\+.*\@/\@/;
	$str_addr;
}

# do not allow Bcc, only Cc and To if recipient is set
sub precheck {
	my ($klass, $filter, $address) = @_;
	my Email::Simple $simple = $filter->simple;
	my @mid = $simple->header('Message-ID');
	return 0 if scalar(@mid) != 1;
	my $mid = $mid[0];
	return 0 if (length($mid) > MAX_MID_SIZE);
	return 0 unless usable_str(length('<m@h>'), $mid) && $mid =~ /\@/;
	return 0 unless usable_str(length('u@h'), $filter->from);
	return 0 unless usable_str(length(':o'), $simple->header("Subject"));
	return 0 unless usable_date($simple->header("Date"));
	return 0 if length($simple->as_string) > MAX_SIZE;
	alias_specified($filter, $address);
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
	my ($filter, $address) = @_;

	my @address = ref($address) eq 'ARRAY' ? @$address : ($address);
	my %ok = map {
		my @recip = Email::Address->parse($_);
		lc(__drop_plus($recip[0]->address)) => 1;
	} @address;

	foreach my $line ($filter->cc, $filter->to) {
		foreach my $addr (Email::Address->parse($line)) {
			if ($ok{lc(__drop_plus($addr->address))}) {
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
		$simple->header_set("List-Id", "<$pa>"); # RFC2919
	}

	foreach my $h (qw(delivered-to), # prevent training loops
			# The rest are taken from Mailman 2.1.15
			# could contain passwords:
			qw(approved approve x-approved x-approve urgent),
			# could be used phishing:
			qw(return-receipt-to disposition-notification-to
			   x-confirm-reading-to),
			# Pegasus mail:
			qw(x-pmrqc)) {
		$simple->header_set($h);
	}
}

# returns a 3-element array: name, email, date
sub author_info {
	my ($class, $mime) = @_;

	my $from = $mime->header('From');
	my @from = Email::Address->parse($from);
	my $name = $from[0]->name;
	my $email = $from[0]->address;
	($name, $email, $mime->header('Date'));
}

1;
