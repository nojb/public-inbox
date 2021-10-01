# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# connects public-inbox processes to PublicInbox::Gcf2::loop()
package PublicInbox::Gcf2Client;
use strict;
use parent qw(PublicInbox::DS);
use PublicInbox::Git;
use PublicInbox::Gcf2; # fails if Inline::C or libgit2-dev isn't available
use PublicInbox::Spawn qw(spawn);
use Socket qw(AF_UNIX SOCK_STREAM);
use PublicInbox::Syscall qw(EPOLLIN EPOLLET);
# fields:
#	sock => socket to Gcf2::loop
# The rest of these fields are compatible with what PublicInbox::Git
# uses code-sharing
#	pid => PID of Gcf2::loop process
#	pid.owner => process which spawned {pid}
#	in => same as {sock}, for compatibility with PublicInbox::Git
#	inflight => array (see PublicInbox::Git)
#	cat_rbuf => scalarref, may be non-existent or empty
sub new  {
	my ($rdr) = @_;
	my $self = bless {}, __PACKAGE__;
	# ensure the child process has the same @INC we do:
	my $env = { PERL5LIB => join(':', @INC) };
	my ($s1, $s2);
	socketpair($s1, $s2, AF_UNIX, SOCK_STREAM, 0) or die "socketpair $!";
	$rdr //= {};
	$rdr->{0} = $rdr->{1} = $s2;
	my $cmd = [$^X, qw[-MPublicInbox::Gcf2 -e PublicInbox::Gcf2::loop]];
	$self->{'pid.owner'} = $$;
	$self->{pid} = spawn($cmd, $env, $rdr);
	$s1->blocking(0);
	$self->{inflight} = [];
	$self->{in} = $s1;
	$self->SUPER::new($s1, EPOLLIN|EPOLLET);
}

sub fail {
	my $self = shift;
	$self->close; # PublicInbox::DS::close
	PublicInbox::Git::fail($self, @_);
}

sub gcf2_async ($$$;$) {
	my ($self, $req, $cb, $arg) = @_;
	my $inflight = $self->{inflight} or return $self->close;

	# {wbuf} is rare, I hope:
	cat_async_step($self, $inflight) if $self->{wbuf};

	$self->fail("gcf2c write: $!") if !$self->write($req) && !$self->{sock};
	push @$inflight, $req, $cb, $arg;
}

# ensure PublicInbox::Git::cat_async_step never calls cat_async_retry
sub alternates_changed {}

# DS::event_loop will call this
sub event_step {
	my ($self) = @_;
	$self->flush_write;
	$self->close if !$self->{in} || !$self->{sock}; # process died
	my $inflight = $self->{inflight};
	if ($inflight && @$inflight) {
		cat_async_step($self, $inflight);
		return $self->close unless $self->{in}; # process died

		# ok, more to do, requeue for fairness
		$self->requeue if @$inflight || exists($self->{cat_rbuf});
	}
}

sub DESTROY {
	my ($self) = @_;
	delete $self->{sock}; # if outside event_loop
	PublicInbox::Git::DESTROY($self);
}

no warnings 'once';

*cat_async_step = \&PublicInbox::Git::cat_async_step;

1;
