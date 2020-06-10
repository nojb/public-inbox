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
		# pi_config => PublicInbox::Config
		# idler => PublicInbox::InboxIdle
	}, $class;
}

sub refresh_inboxlist ($) {
	my ($self) = @_;
	my @names = map { $_->{newsgroup} } @{delete $self->{grouplist}};
	my %ns; # "\Noselect \HasChildren"
	for (@names) {
		my $up = $_;
		while ($up =~ s/\.[^\.]+\z//) {
			$ns{$up} = '\\Noselect \\HasChildren';
		}
	}
	@names = map {;
		my $at = delete($ns{$_}) ? '\\HasChildren' : '\\HasNoChildren';
		qq[* LIST ($at) "." $_\r\n]
	} @names;
	push(@names, map { qq[* LIST ($ns{$_}) "." $_\r\n] } keys %ns);
	@names = sort {
		my ($xa) = ($a =~ / (\S+)\r\n/g);
		my ($xb) = ($b =~ / (\S+)\r\n/g);
		length($xa) <=> length($xb);
	} @names;
	$self->{inboxlist} = \@names;
}

sub refresh_groups {
	my ($self) = @_;
	my $pi_config = $self->{pi_config} = PublicInbox::Config->new;
	$self->SUPER::refresh_groups($pi_config);
	refresh_inboxlist($self);

	if (my $idler = $self->{idler}) {
		$idler->refresh($pi_config);
	}
}

sub idler_start {
	$_[0]->{idler} //= PublicInbox::InboxIdle->new($_[0]->{pi_config});
}

1;
