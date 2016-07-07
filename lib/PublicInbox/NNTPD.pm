# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# represents an NNTPD (currently a singleton),
# see script/public-inbox-nntpd for how it is used
package PublicInbox::NNTPD;
use strict;
use warnings;
require PublicInbox::Config;

sub new {
	my ($class) = @_;
	bless {
		groups => {},
		err => \*STDERR,
		out => \*STDOUT,
		grouplist => [],
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
