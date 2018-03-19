# Copyright (C) 2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Extends read-only Inbox for writing
package PublicInbox::InboxWritable;
use strict;
use warnings;
use base qw(PublicInbox::Inbox);
use PublicInbox::Import;

sub new {
	my ($class, $ibx) = @_;
	bless $ibx, $class;
}

sub importer {
	my ($self, $parallel) = @_;
	$self->{-importer} ||= eval {
		my $v = $self->{version} || 1;
		if ($v == 2) {
			eval { require PublicInbox::V2Writable };
			die "v2 not supported: $@\n" if $@;
			my $v2w = PublicInbox::V2Writable->new($self);
			$v2w->{parallel} = $parallel;
			$v2w;
		} elsif ($v == 1) {
			my $git = $self->git;
			my $name = $self->{name};
			my $addr = $self->{-primary_address};
			PublicInbox::Import->new($git, $name, $addr, $self);
		} else {
			die "unsupported inbox version: $v\n";
		}
	}
}

sub filter {
	my ($self) = @_;
	my $f = $self->{filter};
	if ($f && $f =~ /::/) {
		my @args = (-inbox => $self);
		# basic line splitting, only
		# Perhaps we can have proper quote splitting one day...
		($f, @args) = split(/\s+/, $f) if $f =~ /\s+/;

		eval "require $f";
		if ($@) {
			warn $@;
		} else {
			# e.g: PublicInbox::Filter::Vger->new(@args)
			return $f->new(@args);
		}
	}
	undef;
}

1;
