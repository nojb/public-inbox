# Copyright (C) 2016-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Wrap a pipe or file for PSGI streaming response bodies and calls the
# end callback when the object goes out-of-scope.
# This depends on rpipe being _blocking_ on getline.
#
# public-inbox-httpd favors "getline" response bodies to take a
# "pull"-based approach to feeding slow clients (as opposed to a
# more common "push" model)
package PublicInbox::GetlineBody;
use strict;
use warnings;

sub new {
	my ($class, $rpipe, $end, $buf, $filter) = @_;
	bless {
		rpipe => $rpipe,
		end => $end,
		buf => $buf,
		filter => $filter || 0,
	}, $class;
}

# close should always be called after getline returns undef,
# but a client aborting a connection can ruin our day; so lets
# hope our underlying PSGI server does not leak references, here.
sub DESTROY { $_[0]->close }

sub getline {
	my ($self) = @_;
	my $filter = $self->{filter};
	return if $filter == -1; # last call was EOF

	my $buf = delete $self->{buf}; # initial buffer
	$buf = $self->{rpipe}->getline unless defined $buf;
	$self->{filter} = -1 unless defined $buf; # set EOF for next call
	$filter ? $filter->($buf) : $buf;
}

sub close {
	my ($self) = @_;
	my $rpipe = delete $self->{rpipe};
	close $rpipe if $rpipe;
	my $end = delete $self->{end};
	$end->() if $end;
}

1;
