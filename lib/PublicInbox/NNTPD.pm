# Copyright (C) 2016-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# represents an NNTPD (currently a singleton),
# see script/public-inbox-nntpd for how it is used
package PublicInbox::NNTPD;
use strict;
use warnings;
use Sys::Hostname;
use PublicInbox::Config;

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
		servername => $name,
		greet => \"201 $name ready - post via email\r\n",
		# accept_tls => { SSL_server => 1, ..., SSL_reuse_ctx => ... }
	}, $class;
}

sub refresh_groups () {
	my ($self) = @_;
	my $pi_config = PublicInbox::Config->new;
	my $new = {};
	my @list;
	$pi_config->each_inbox(sub {
		my ($ng) = @_;
		my $ngname = $ng->{newsgroup} or return;
		if (ref $ngname) {
			warn 'multiple newsgroups not supported: '.
				join(', ', @$ngname). "\n";
		} elsif ($ng->nntp_usable) {
			# Only valid if msgmap and search works
			$new->{$ngname} = $ng;
			push @list, $ng;
		}
	});
	@list =	sort { $a->{newsgroup} cmp $b->{newsgroup} } @list;
	$self->{grouplist} = \@list;
	# this will destroy old groups that got deleted
	%{$self->{groups}} = %$new;
}

1;
