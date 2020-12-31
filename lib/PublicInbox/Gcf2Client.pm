# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# connects public-inbox processes to PublicInbox::Gcf2::loop()
package PublicInbox::Gcf2Client;
use strict;
use parent qw(PublicInbox::DS);
use PublicInbox::Git;
use PublicInbox::Spawn qw(popen_rd);
use IO::Handle ();
use PublicInbox::Syscall qw(EPOLLONESHOT);
# fields:
#	async_cat => GitAsyncCat ref (read-only pipe)
#	sock => writable pipe to Gcf2::loop
#	in => pipe we read from
#	pid => PID of Gcf2::loop process
sub new  {
	my ($rdr) = @_;
	my $self = bless {}, __PACKAGE__;
	# ensure the child process has the same @INC we do:
	my $env = { PERL5LIB => join(':', @INC) };
	my ($out_r, $out_w);
	pipe($out_r, $out_w) or die "pipe failed: $!";
	$rdr //= {};
	$rdr->{0} = $out_r;
	my $cmd = [$^X, qw[-MPublicInbox::Gcf2 -e PublicInbox::Gcf2::loop()]];
	@$self{qw(in pid)} = popen_rd($cmd, $env, $rdr);
	fcntl($out_w, 1031, 4096) if $^O eq 'linux'; # 1031: F_SETPIPE_SZ
	$out_w->autoflush(1);
	$out_w->blocking(0);
	$self->{inflight} = [];
	$self->SUPER::new($out_w, EPOLLONESHOT); # detect errors once
}

sub fail {
	my $self = shift;
	$self->close; # PublicInbox::DS::close
	PublicInbox::Git::fail($self, @_);
}

sub cat_async ($$$;$) {
	my ($self, $req, $cb, $arg) = @_;
	my $inflight = $self->{inflight};

	# {wbuf} is rare, I hope:
	cat_async_step($self, $inflight) if $self->{wbuf};

	if (!$self->write(\"$req\n")) {
		$self->fail("gcf2c write: $!") if !$self->{sock};
	}
	push @$inflight, $req, $cb, $arg;
}

# ensure PublicInbox::Git::cat_async_step never calls cat_async_retry
sub alternates_changed {}

# this is the write-only end of a pipe, DS->EventLoop will call this
sub event_step {
	my ($self) = @_;
	$self->flush_write;
	$self->close if !$self->{in}; # process died
}

no warnings 'once';

sub DESTROY {
	my ($self) = @_;
	my $pid = delete $self->{pid};
	delete $self->{in};
	return unless $pid;
	eval {
		PublicInbox::DS::dwaitpid($pid, undef, undef);
		$self->close; # we're still in the event loop
	};
	if ($@) { # wait synchronously if not in event loop
		my $sock = delete $self->{sock};
		close $sock if $sock;
		waitpid($pid, 0);
	}
}

# used by GitAsyncCat
*cat_async_step = \&PublicInbox::Git::cat_async_step;

1;
