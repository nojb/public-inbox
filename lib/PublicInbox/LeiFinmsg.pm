# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Finalization messages, used to queue up a bunch of messages which
# only get written out on ->DESTROY
package PublicInbox::LeiFinmsg;
use strict;
use v5.10.1;

sub new {
	my ($cls, $lei) = @_;
	bless [ @$lei{qw(2 sock)}, $$ ], $cls;
}

sub DESTROY {
	my ($self) = @_;
	my ($stderr, $sock, $pid) = splice(@$self, 0, 3);
	print $stderr @$self if $pid == $$;
	# script/lei disconnects when $sock SvREFCNT drops to zero
}

1;
