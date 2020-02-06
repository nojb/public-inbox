# Copyright (C) 2016-2020 all contributors <meta@public-inbox.org>
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
	my ($class, $rpipe, $end, $end_arg, $buf) = @_;
	bless {
		rpipe => $rpipe,
		end => $end,
		end_arg => $end_arg,
		buf => $buf,
		filter => 0,
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
	$buf;
}

sub close {
	my ($self) = @_;
	my ($rpipe, $end, $end_arg) = delete @$self{qw(rpipe end end_arg)};
	close $rpipe if $rpipe;
	$end->($end_arg) if $end;
}

1;
