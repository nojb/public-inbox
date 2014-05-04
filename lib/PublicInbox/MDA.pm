# Copyright (C) 2013, Eric Wong <normalperson@yhbt.net> and all contributors
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
package PublicInbox::MDA;
use strict;
use warnings;
use Email::Address;
use Encode qw/decode/;
use Date::Parse qw(strptime);
use constant MAX_SIZE => 1024 * 500; # same as spamc default, should be tunable
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
	my $simple = $filter->simple;
	my $mid = $simple->header("Message-ID");
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

# RFC2919 and RFC2369
sub set_list_headers {
	my ($class, $simple, $dst) = @_;
	my $pa = "<$dst->{-primary_address}>";
	$simple->header_set("List-Id", $pa);
	$simple->header_set("List-Post", $pa);

	my $url = $dst->{url};
	if (defined $url) {
		$simple->header_set("List-Archive", "<$url>");
		$simple->header_set("List-Help", "<${url}help>");
	}
}

# returns a 3-element array: name, email, date
sub author_info {
	my ($class, $mime) = @_;

	my $from = $mime->header('From');
	my @from = Email::Address->parse($from);
	my $name = $from[0]->name;
	defined $name or $name = '';
	my $email = $from[0]->address;
	defined $email or $email = '';
	($name, $email, $mime->header('Date'));
}

1;
