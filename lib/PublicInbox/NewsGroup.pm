# Copyright (C) 2015 all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
#
# Used only by the NNTP server to represent a public-inbox git repository
# as a newsgroup
package PublicInbox::NewsGroup;
use strict;
use warnings;
use Scalar::Util qw(weaken);
require Danga::Socket;
require PublicInbox::Msgmap;
require PublicInbox::Search;
require PublicInbox::Git;

sub new {
	my ($class, $name, $git_dir, $address) = @_;
	$address = $address->[0] if ref($address);
	my $self = bless {
		name => $name,
		git_dir => $git_dir,
		address => $address,
	}, $class;
	$self->{domain} = ($address =~ /\@(\S+)\z/) ? $1 : 'localhost';
	$self;
}

sub weaken_all {
	my ($self) = @_;
	weaken($self->{$_}) foreach qw(gcf mm search);
}

sub gcf {
	my ($self) = @_;
	$self->{gcf} ||= eval { PublicInbox::Git->new($self->{git_dir}) };
}

sub usable {
	my ($self) = @_;
	eval {
		PublicInbox::Msgmap->new($self->{git_dir});
		PublicInbox::Search->new($self->{git_dir});
	};
}

sub mm {
	my ($self) = @_;
	$self->{mm} ||= eval { PublicInbox::Msgmap->new($self->{git_dir}) };
}

sub search {
	my ($self) = @_;
	$self->{search} ||= eval { PublicInbox::Search->new($self->{git_dir}) };
}

sub description {
	my ($self) = @_;
	open my $fh, '<', "$self->{git_dir}/description" or return '';
	my $desc = eval { local $/; <$fh> };
	chomp $desc;
	$desc =~ s/\s+/ /smg;
	$desc;
}

sub update {
	my ($self, $new) = @_;
	$self->{address} = $new->{address};
	$self->{domain} = $new->{domain};
	if ($self->{git_dir} ne $new->{git_dir}) {
		# new git_dir requires a new mm and gcf
		$self->{mm} = $self->{gcf} = undef;
		$self->{git_dir} = $new->{git_dir};
	}
}

1;
