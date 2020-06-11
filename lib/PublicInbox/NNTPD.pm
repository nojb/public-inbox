# Copyright (C) 2016-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# represents an NNTPD (currently a singleton),
# see script/public-inbox-nntpd for how it is used
package PublicInbox::NNTPD;
use strict;
use warnings;
use Sys::Hostname;
use PublicInbox::Config;
use PublicInbox::InboxIdle;

sub new {
	my ($class) = @_;
	my $pi_config = PublicInbox::Config->new;
	my $name = $pi_config->{'publicinbox.nntpserver'};
	if (!defined($name) or $name eq '') {
		$name = hostname;
	} elsif (ref($name) eq 'ARRAY') {
		$name = $name->[0];
	}

	bless {
		groups => {},
		err => \*STDERR,
		out => \*STDOUT,
		grouplist => [],
		pi_config => $pi_config,
		servername => $name,
		greet => \"201 $name ready - post via email\r\n",
		# accept_tls => { SSL_server => 1, ..., SSL_reuse_ctx => ... }
		# idler => PublicInbox::InboxIdle
	}, $class;
}

sub refresh_groups {
	my ($self, $sig) = @_;
	my $pi_config = $sig ? PublicInbox::Config->new : $self->{pi_config};
	my $new = {};
	my @list;
	$pi_config->each_inbox(sub {
		my ($ng) = @_;
		my $ngname = $ng->{newsgroup} or return;
		if (ref $ngname) {
			warn 'multiple newsgroups not supported: '.
				join(', ', @$ngname). "\n";
		# Newsgroup name needs to be compatible with RFC 3977
		# wildmat-exact and RFC 3501 (IMAP) ATOM-CHAR.
		# Leave out a few chars likely to cause problems or conflicts:
		# '|', '<', '>', ';', '#', '$', '&',
		} elsif ($ngname =~ m![^A-Za-z0-9/_\.\-\~\@\+\=:]!) {
			warn "newsgroup name invalid: `$ngname'\n";
		} elsif ($ng->nntp_usable) {
			# Only valid if msgmap and search works
			$new->{$ngname} = $ng;
			push @list, $ng;

			# preload to avoid fragmentation:
			$ng->description;
			$ng->base_url;
		}
	});
	@list =	sort { $a->{newsgroup} cmp $b->{newsgroup} } @list;
	$self->{grouplist} = \@list;
	$self->{pi_config} = $pi_config;
	# this will destroy old groups that got deleted
	%{$self->{groups}} = %$new;
}

sub idler_start {
	$_[0]->{idler} //= PublicInbox::InboxIdle->new($_[0]->{pi_config});
}

1;
