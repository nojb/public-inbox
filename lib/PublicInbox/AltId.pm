# Copyright (C) 2016-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

package PublicInbox::AltId;
use strict;
use warnings;
use URI::Escape qw(uri_unescape);

# spec: TYPE:PREFIX:param1=value1&param2=value2&...
# Example: serial:gmane:file=/path/to/altmsgmap.sqlite3
sub new {
	my ($class, $inbox, $spec, $writable) = @_;
	my ($type, $prefix, $query) = split(/:/, $spec, 3);
	$type eq 'serial' or die "non-serial not supported, yet\n";

	require PublicInbox::Msgmap;

	my %params = map {
		my ($k, $v) = split(/=/, uri_unescape($_), 2);
		$v = '' unless defined $v;
		($k, $v);
	} split(/[&;]/, $query);
	my $f = $params{file} or die "file: required for $type spec $spec\n";
	unless (index($f, '/') == 0) {
		if (($inbox->{version} || 1) == 1) {
			$f = "$inbox->{mainrepo}/public-inbox/$f";
		} else {
			$f = "$inbox->{mainrepo}/$f";
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
		my $writable = $self->{filename};
		PublicInbox::Msgmap->new_file($f, $writable);
	};
}

sub mid2alt {
	my ($self, $mid) = @_;
	$self->mm_alt->num_for($mid);
}

1;
