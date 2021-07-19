# Copyright all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# dummy placeholder socket for internal lei commands.
# This receives what script/lei receives, but isn't connected
# to an interactive terminal so I'm not sure what to do with it...
package PublicInbox::LeiSelfSocket;
use strict;
use v5.10.1;
use parent qw(PublicInbox::DS);
use Data::Dumper;
$Data::Dumper::Useqq = 1; # should've been the Perl default :P
use PublicInbox::Syscall qw(EPOLLIN EPOLLET);
use PublicInbox::Spawn;
my $recv_cmd;

sub new {
	my ($cls, $r) = @_;
	my $self = bless { sock => $r }, $cls;
	$r->blocking(0);
	no warnings 'once';
	$recv_cmd = $PublicInbox::LEI::recv_cmd;
	$self->SUPER::new($r, EPOLLIN|EPOLLET);
}

sub event_step {
	my ($self) = @_;
	while (1) {
		my (@fds) = $recv_cmd->($self->{sock}, my $buf, 4096 * 33);
		if (scalar(@fds) == 1 && !defined($fds[0])) {
			return if $!{EAGAIN};
			next if $!{EINTR};
			die "recvmsg: $!";
		}
		# open so perl can auto-close them:
		for my $fd (@fds) {
			open(my $newfh, '+<&=', $fd) or die "open +<&=$fd: $!";
		}
		return $self->close if $buf eq '';
		warn Dumper({ 'unexpected self msg' => $buf, fds => \@fds });
		# TODO: figure out what to do with these messages...
	}
}

1;
