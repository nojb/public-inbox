# Copyright (C) 2015 all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
package PublicInbox::NewsGroup;
use strict;
use warnings;
use fields qw(name git_dir address domain mm gcf search);
use Scalar::Util qw(weaken);
require Danga::Socket;
require PublicInbox::Msgmap;
require PublicInbox::GitCatFile;

sub new {
	my ($class, $name, $git_dir, $address) = @_;
	my $self = fields::new($class);
	$self->{name} = $name;
	$address = $address->[0] if ref($address);
	$self->{domain} = ($address =~ /\@(\S+)\z/) ? $1 : 'localhost';
	$self->{git_dir} = $git_dir;
	$self->{address} = $address;
	$self;
}

sub defer_weaken {
	my ($self, $field) = @_;
	Danga::Socket->AddTimer(30, sub { weaken($self->{$field}) });
}

sub gcf {
	my ($self) = @_;
	$self->{gcf} ||= eval {
		my $gcf = PublicInbox::GitCatFile->new($self->{git_dir});

		# git repos may be repacked and old packs unlinked
		defer_weaken($self, 'gcf');
		$gcf;
	};
}

sub mm {
	my ($self, $check_only) = @_;
	if ($check_only) {
		return eval { PublicInbox::Msgmap->new($self->{git_dir}) };
	}
	$self->{mm} ||= eval {
		my $mm = PublicInbox::Msgmap->new($self->{git_dir});

		# may be needed if we run low on handles
		defer_weaken($self, 'mm');
		$mm;
	};
}

sub search {
	my ($self) = @_;
	$self->{search} ||= eval {
		require PublicInbox::Search;
		my $search = PublicInbox::Search->new($self->{git_dir});

		# may be needed if we run low on handles
		defer_weaken($self, 'search');
		$search;
	};
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
