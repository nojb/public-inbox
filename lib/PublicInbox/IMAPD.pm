# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# represents an IMAPD (currently a singleton),
# see script/public-inbox-imapd for how it is used
package PublicInbox::IMAPD;
use strict;
use parent qw(PublicInbox::NNTPD);
use PublicInbox::InboxIdle;

sub new {
	my ($class) = @_;
	bless {
		groups => {},
		err => \*STDERR,
		out => \*STDOUT,
		grouplist => [],
		# accept_tls => { SSL_server => 1, ..., SSL_reuse_ctx => ... }
		# idler => PublicInbox::InboxIdle
	}, $class;
}

sub refresh_groups {
	my ($self) = @_;
	if (my $old_idler = delete $self->{idler}) {
		$old_idler->close; # PublicInbox::DS::close
	}
	my $pi_config = PublicInbox::Config->new;
	$self->{idler} = PublicInbox::InboxIdle->new($pi_config);
	$self->SUPER::refresh_groups($pi_config);
}

1;
