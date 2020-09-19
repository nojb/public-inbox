# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# connects public-inbox processes to PublicInbox::Gcf2::loop()
package PublicInbox::Gcf2Client;
use strict;
use parent qw(PublicInbox::DS);
use PublicInbox::Git;
use PublicInbox::Spawn qw(popen_rd);
use IO::Handle ();
use PublicInbox::Syscall qw(EPOLLONESHOT EPOLLOUT);
# fields:
#	async_cat => GitAsyncCat ref (read-only pipe)
#	sock => writable pipe to Gcf2::loop

sub new { bless($_[0] // {}, __PACKAGE__) }

sub gcf2c_begin ($) {
	my ($self) = @_;
	# ensure the child process has the same @INC we do:
	my $env = { PERL5LIB => join(':', @INC) };
	my ($out_r, $out_w);
	pipe($out_r, $out_w) or die "pipe failed: $!";
	my $rdr = { 0 => $out_r, 2 => $self->{2} };
	my $cmd = [$^X, qw[-MPublicInbox::Gcf2 -e PublicInbox::Gcf2::loop()]];
	@$self{qw(in pid)} = popen_rd($cmd, $env, $rdr);
	fcntl($out_w, 1031, 4096) if $^O eq 'linux'; # 1031: F_SETPIPE_SZ
	$out_w->autoflush(1);
	$out_w->blocking(0);
	$self->SUPER::new($out_w, 0); # EPOLL_CTL_ADD (a bit wasteful :x)
	$self->{inflight} = [];
}

sub fail {
	my $self = shift;
	$self->close; # PublicInbox::DS::close
	PublicInbox::Git::fail($self, @_);
}

sub cat_async ($$$;$) {
	my ($self, $req, $cb, $arg) = @_;
	my $inflight = $self->{inflight} // gcf2c_begin($self);

	# rare, I hope:
	cat_async_step($self, $inflight) if $self->{wbuf};

	$self->write(\"$req\n") or $self->fail("gcf2c write: $!");
	push @$inflight, $req, $cb, $arg;
}

# ensure PublicInbox::Git::cat_async_step never calls cat_async_retry
sub alternates_changed {}

no warnings 'once';

# this is the write-only end of a pipe, DS->EventLoop will call this
*event_step = \&PublicInbox::DS::flush_write;

# used by GitAsyncCat
*cat_async_step = \&PublicInbox::Git::cat_async_step;

1;
