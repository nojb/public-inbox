# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# forwards stderr from lei/store process to any lei clients using
# the same store
package PublicInbox::LeiStoreErr;
use strict;
use v5.10.1;
use parent qw(PublicInbox::DS);
use PublicInbox::Syscall qw(EPOLLIN EPOLLONESHOT);
use Sys::Syslog qw(openlog syslog closelog);
use IO::Handle (); # ->blocking

sub new {
	my ($cls, $rd, $lei) = @_;
	my $self = bless { sock => $rd, store_path => $lei->store_path }, $cls;
	$rd->blocking(0);
	$self->SUPER::new($rd, EPOLLIN | EPOLLONESHOT);
}

sub event_step {
	my ($self) = @_;
	my $rbuf = $self->{rbuf} // \(my $x = '');
	$self->do_read($rbuf, 8192, length($$rbuf)) or return;
	my $cb;
	my $printed;
	for my $lei (values %PublicInbox::DS::DescriptorMap) {
		$cb = $lei->can('store_path') // next;
		next if $cb->($lei) ne $self->{store_path};
		my $err = $lei->{2} // next;
		print $err $$rbuf and $printed = 1;
	}
	if (!$printed) {
		openlog('lei-store', 'pid,nowait,nofatal,ndelay', 'user');
		for my $l (split(/\n/, $$rbuf)) { syslog('warning', '%s', $l) }
		closelog(); # don't share across fork
	}
}

1;
