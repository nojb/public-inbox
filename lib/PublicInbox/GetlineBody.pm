# Copyright (C) 2016-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Wrap a pipe or file for PSGI streaming response bodies and calls the
# end callback when the object goes out-of-scope.
# This depends on rpipe being _blocking_ on getline.
#
# This is only used by generic PSGI servers and not public-inbox-httpd
package PublicInbox::GetlineBody;
use strict;
use warnings;

sub new {
	my ($class, $rpipe, $end, $end_arg, $buf, $filter) = @_;
	bless {
		rpipe => $rpipe,
		end => $end,
		end_arg => $end_arg,
		initial_buf => $buf,
		filter => $filter,
	}, $class;
}

# close should always be called after getline returns undef,
# but a client aborting a connection can ruin our day; so lets
# hope our underlying PSGI server does not leak references, here.
sub DESTROY { $_[0]->close }

sub getline {
	my ($self) = @_;
	my $rpipe = $self->{rpipe} or return; # EOF was set on previous call
	my $buf = delete($self->{initial_buf}) // $rpipe->getline;
	delete($self->{rpipe}) unless defined $buf; # set EOF for next call
	if (my $filter = $self->{filter}) {
		$buf = $filter->translate($buf);
	}
	$buf;
}

sub close {
	my ($self) = @_;
	my ($end, $end_arg) = delete @$self{qw(end end_arg)};
	$end->($end_arg) if $end;
}

1;
