# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# forwards stderr from lei/store process to any lei clients using
# the same store, falls back to syslog if no matching clients exist.
package PublicInbox::LeiStoreErr;
use v5.12;
use parent qw(PublicInbox::DS);
use PublicInbox::Syscall qw(EPOLLIN);
use Sys::Syslog qw(openlog syslog closelog);
use IO::Handle (); # ->blocking

sub new {
	my ($cls, $rd, $lei) = @_;
	my $self = bless { sock => $rd, store_path => $lei->store_path }, $cls;
	$rd->blocking(0);
	$self->SUPER::new($rd, EPOLLIN); # level-trigger
}

sub event_step {
	my ($self) = @_;
	my $n = sysread($self->{sock}, my $buf, 8192);
	return ($!{EAGAIN} ? 0 : $self->close) if !defined($n);
	return $self->close if !$n;
	my $printed;
	for my $lei (values %PublicInbox::DS::DescriptorMap) {
		my $cb = $lei->can('store_path') // next;
		next if $cb->($lei) ne $self->{store_path};
		my $err = $lei->{2} // next;
		print $err $buf and $printed = 1;
	}
	if (!$printed) {
		openlog('lei/store', 'pid,nowait,nofatal,ndelay', 'user');
		for my $l (split(/\n/, $buf)) { syslog('warning', '%s', $l) }
		closelog(); # don't share across fork
	}
}

1;
