# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# represents an NNTPD (currently a singleton),
# see script/public-inbox-nntpd for how it is used
package PublicInbox::NNTPD;
use strict;
use warnings;
require PublicInbox::NewsGroup;
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
		my $g = $1;
		my $git_dir = $pi_config->{$k};
		my $addr = $pi_config->{"publicinbox.$g.address"};
		my $ngname = $pi_config->{"publicinbox.$g.newsgroup"};
		my $url = $pi_config->{"publicinbox.$g.url"};
		if (defined $ngname) {
			next if ($ngname eq ''); # disabled
			$g = $ngname;
		}
		my $ng = PublicInbox::NewsGroup->new($g, $git_dir, $addr, $url);
		my $old_ng = $self->{groups}->{$g};

		# Reuse the old one if possible since it can hold
		# references to valid mm and gcf objects
		if ($old_ng) {
			$old_ng->update($ng);
			$ng = $old_ng;
		}

		# Only valid if msgmap and search works
		if ($ng->usable) {
			$new->{$g} = $ng;
			push @list, $ng;
		}
	}
	@list =	sort { $a->{name} cmp $b->{name} } @list;
	$self->{grouplist} = \@list;
	# this will destroy old groups that got deleted
	%{$self->{groups}} = %$new;
}

1;
