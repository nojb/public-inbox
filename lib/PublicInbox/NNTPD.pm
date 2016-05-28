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
	foreach my $k (keys %$pi_config) {
		$k =~ /\Apublicinbox\.([^\.]+)\.mainrepo\z/ or next;
		my $name = $1;
		my $git_dir = $pi_config->{$k};
		my $ngname = $pi_config->{"publicinbox.$name.newsgroup"};
		next unless defined $ngname;
		next if ($ngname eq ''); # disabled
		my $ng = $pi_config->lookup_newsgroup($ngname) or next;

		# Only valid if msgmap and search works
		if ($ng->nntp_usable) {
			$new->{$ngname} = $ng;
			push @list, $ng;
		}
	}
	@list =	sort { $a->{newsgroup} cmp $b->{newsgroup} } @list;
	$self->{grouplist} = \@list;
	# this will destroy old groups that got deleted
	%{$self->{groups}} = %$new;
}

1;
