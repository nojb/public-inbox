# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Finalization messages, used to queue up a bunch of messages which
# only get written out on ->DESTROY
package PublicInbox::LeiFinmsg;
use strict;
use v5.10.1;

sub new {
	my ($cls, $io) = @_;
	bless [ $io, $$ ], $cls;
}

sub DESTROY {
	my ($self) = @_;
	my $io = shift @$self;
	shift(@$self) == $$ and print $io @$self;
}

1;
