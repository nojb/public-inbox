# Copyright (C) 2016-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Used for giving serial numbers to messages.  This can be tied to
# the msgmap for live updates to living lists (see
# PublicInbox::Filters::RubyLang), or kept separate for imports
# of defunct NNTP groups (e.g. scripts/xhdr-num2mid)
#
# Introducing NEW uses of serial numbers is discouraged because of
# it leads to reliance on centralization.  However, being able
# to use existing serial numbers is beneficial.
package PublicInbox::AltId;
use strict;
use warnings;
use URI::Escape qw(uri_unescape);
use PublicInbox::Msgmap;

# spec: TYPE:PREFIX:param1=value1&param2=value2&...
# The PREFIX will be a searchable boolean prefix in Xapian
# Example: serial:gmane:file=/path/to/altmsgmap.sqlite3
sub new {
	my ($class, $ibx, $spec, $writable) = @_;
	my ($type, $prefix, $query) = split(/:/, $spec, 3);
	$type eq 'serial' or die "non-serial not supported, yet\n";

	my %params = map {
		my ($k, $v) = split(/=/, uri_unescape($_), 2);
		$v = '' unless defined $v;
		($k, $v);
	} split(/[&;]/, $query);
	my $f = $params{file} or die "file: required for $type spec $spec\n";
	unless (index($f, '/') == 0) {
		if (($ibx->{version} || 1) == 1) {
			$f = "$ibx->{inboxdir}/public-inbox/$f";
		} else {
			$f = "$ibx->{inboxdir}/$f";
		}
	}
	bless {
		filename => $f,
		writable => $writable,
		xprefix => 'X'.uc($prefix),
	}, $class;
}

sub mm_alt {
	my ($self) = @_;
	$self->{mm_alt} ||= eval {
		my $f = $self->{filename};
		my $writable = $self->{writable};
		PublicInbox::Msgmap->new_file($f, $writable);
	};
}

sub mid2alt {
	my ($self, $mid) = @_;
	$self->mm_alt->num_for($mid);
}

1;
