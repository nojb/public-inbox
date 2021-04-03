# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# forwards stderr from lei/store process to any lei clients using
# the same store
package PublicInbox::LeiStoreErr;
use strict;
use v5.10.1;
use parent qw(PublicInbox::DS);
use PublicInbox::Syscall qw(EPOLLIN EPOLLONESHOT);

sub new {
	my ($cls, $rd, $lei) = @_;
	my $self = bless { sock => $rd, store_path => $lei->store_path }, $cls;
	$self->SUPER::new($rd, EPOLLIN | EPOLLONESHOT);
}

sub event_step {
	my ($self) = @_;
	$self->do_read(\(my $rbuf), 4096) or return;
	my $cb;
	for my $lei (values %PublicInbox::DS::DescriptorMap) {
		$cb = $lei->can('store_path') // next;
		next if $cb->($lei) ne $self->{store_path};
		my $err = $lei->{2} // next;
		print $err $rbuf;
	}
}

1;
