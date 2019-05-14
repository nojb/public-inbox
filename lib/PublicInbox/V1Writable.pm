# Copyright (C) 2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# This interface wraps PublicInbox::Import and makes it closer
# to V2Writable
# Used to write to V1 inboxes (see L<public-inbox-v1-format(5)>).
package PublicInbox::V1Writable;
use strict;
use warnings;
use base qw(PublicInbox::Import);
use PublicInbox::InboxWritable;

sub new {
	my ($class, $ibx, $creat) = @_;
	my $dir = $ibx->{mainrepo} or die "no mainrepo in inbox\n";
	unless (-d $dir) {
		if ($creat) {
			PublicInbox::Import::init_bare($dir);
		} else {
			die "$dir does not exist\n";
		}
	}
	$ibx = PublicInbox::InboxWritable->new($ibx);
	$class->SUPER::new(undef, undef, undef, $ibx);
}

sub init_inbox {
	my ($self, $partitions, $skip_epoch, $skip_artnum) = @_;
	# TODO: honor skip_artnum
	my $dir = $self->{-inbox}->{mainrepo} or die "no mainrepo in inbox\n";
	PublicInbox::Import::init_bare($dir);
}

1;
