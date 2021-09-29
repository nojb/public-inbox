# This library is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.
#
# This license differs from the rest of public-inbox
#
# This is a fork of the unmaintained Danga::Socket (1.61) with
# significant changes.  See Documentation/technical/ds.txt in our
# source for details.
#
# Do not expect this to be a stable API like Danga::Socket,
# but it will evolve to suite our needs and to take advantage of
# newer Linux and *BSD features.
# Bugs encountered were reported to bug-Danga-Socket@rt.cpan.org,
# fixed in Danga::Socket 1.62 and visible at:
# https://rt.cpan.org/Public/Dist/Display.html?Name=Danga-Socket
#
# fields:
# sock: underlying socket
# rbuf: scalarref, usually undef
# wbuf: arrayref of coderefs or tmpio (autovivified))
#        (tmpio = [ GLOB, offset, [ length ] ])
package PublicInbox::DS;
use strict;
use v5.10.1;
use parent qw(Exporter);
use bytes qw(length substr); # FIXME(?): needed for PublicInbox::NNTP
use POSIX qw(WNOHANG sigprocmask SIG_SETMASK);
use Fcntl qw(SEEK_SET :DEFAULT O_APPEND);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
use Scalar::Util qw(blessed);
use PublicInbox::Syscall qw(:epoll);
use PublicInbox::Tmpfile;
use Errno qw(EAGAIN EINVAL);
use Carp qw(carp croak);
our @EXPORT_OK = qw(now msg_more dwaitpid add_timer add_uniq_timer);

my %Stack;
my $nextq; # queue for next_tick
my $wait_pids; # list of [ pid, callback, callback_arg ]
my $later_q; # list of callbacks to run at some later interval
my $EXPMAP; # fd -> idle_time
our $EXPTIME = 180; # 3 minutes
my ($reap_armed);
my $ToClose; # sockets to close when event loop is done
our (
     %DescriptorMap,             # fd (num) -> PublicInbox::DS object
     $Epoll,                     # Global epoll fd (or DSKQXS ref)
     $_io,                       # IO::Handle for Epoll

     $PostLoopCallback,          # subref to call at the end of each loop, if defined (global)

     $LoopTimeout,               # timeout of event loop in milliseconds
     @Timers,                    # timers
     %UniqTimer,
     $in_loop,
     );

Reset();

#####################################################################
### C L A S S   M E T H O D S
#####################################################################

=head2 C<< CLASS->Reset() >>

Reset all state

=cut
sub Reset {
	do {
		$in_loop = undef; # first in case DESTROY callbacks use this
		%DescriptorMap = ();
		@Timers = ();
		%UniqTimer = ();
		$PostLoopCallback = undef;

		# we may be iterating inside one of these on our stack
		my @q = delete @Stack{keys %Stack};
		for my $q (@q) { @$q = () }
		$EXPMAP = undef;
		$wait_pids = $later_q = $nextq = $ToClose = undef;
		$_io = undef; # closes real $Epoll FD
		$Epoll = undef; # may call DSKQXS::DESTROY
	} while (@Timers || keys(%Stack) || $nextq || $wait_pids ||
		$later_q || $ToClose || keys(%DescriptorMap) ||
		$PostLoopCallback || keys(%UniqTimer));

	$reap_armed = undef;
	$LoopTimeout = -1;  # no timeout by default
}

=head2 C<< CLASS->SetLoopTimeout( $timeout ) >>

Set the loop timeout for the event loop to some value in milliseconds.

A timeout of 0 (zero) means poll forever. A timeout of -1 means poll and return
immediately.

=cut
sub SetLoopTimeout { $LoopTimeout = $_[1] + 0 }

sub _add_named_timer {
	my ($name, $secs, $coderef, @args) = @_;
	my $fire_time = now() + $secs;
	my $timer = [$fire_time, $name, $coderef, @args];

	if (!@Timers || $fire_time >= $Timers[-1][0]) {
		push @Timers, $timer;
		return $timer;
	}

	# Now, where do we insert?  (NOTE: this appears slow, algorithm-wise,
	# but it was compared against calendar queues, heaps, naive push/sort,
	# and a bunch of other versions, and found to be fastest with a large
	# variety of datasets.)
	for (my $i = 0; $i < @Timers; $i++) {
		if ($Timers[$i][0] > $fire_time) {
			splice(@Timers, $i, 0, $timer);
			return $timer;
		}
	}
	die "Shouldn't get here.";
}

sub add_timer { _add_named_timer(undef, @_) }

sub add_uniq_timer { # ($name, $secs, $coderef, @args) = @_;
	$UniqTimer{$_[0]} //= _add_named_timer(@_);
}

# keeping this around in case we support other FD types for now,
# epoll_create1(EPOLL_CLOEXEC) requires Linux 2.6.27+...
sub set_cloexec ($) {
    my ($fd) = @_;

    open($_io, '+<&=', $fd) or return;
    defined(my $fl = fcntl($_io, F_GETFD, 0)) or return;
    fcntl($_io, F_SETFD, $fl | FD_CLOEXEC);
}

# caller sets return value to $Epoll
sub _InitPoller
{
    if (PublicInbox::Syscall::epoll_defined())  {
        my $fd = epoll_create();
        set_cloexec($fd) if (defined($fd) && $fd >= 0);
	$fd;
    } else {
        my $cls;
        for (qw(DSKQXS DSPoll)) {
            $cls = "PublicInbox::$_";
            last if eval "require $cls";
        }
        $cls->import(qw(epoll_ctl epoll_wait));
        $cls->new;
    }
}

=head2 C<< CLASS->EventLoop() >>

Start processing IO events. In most daemon programs this never exits. See
C<PostLoopCallback> below for how to exit the loop.

=cut

sub now () { clock_gettime(CLOCK_MONOTONIC) }

sub next_tick () {
	my $q = $nextq or return;
	$nextq = undef;
	$Stack{cur_runq} = $q;
	for my $obj (@$q) {
		# avoid "ref" on blessed refs to workaround a Perl 5.16.3 leak:
		# https://rt.perl.org/Public/Bug/Display.html?id=114340
		if (blessed($obj)) {
			$obj->event_step;
		} else {
			$obj->();
		}
	}
	delete $Stack{cur_runq};
}

# runs timers and returns milliseconds for next one, or next event loop
sub RunTimers {
	next_tick();

	return (($nextq || $ToClose) ? 0 : $LoopTimeout) unless @Timers;

	my $now = now();

	# Run expired timers
	while (@Timers && $Timers[0][0] <= $now) {
		my $to_run = shift(@Timers);
		delete $UniqTimer{$to_run->[1] // ''};
		$to_run->[2]->(@$to_run[3..$#$to_run]);
	}

	# timers may enqueue into nextq:
	return 0 if ($nextq || $ToClose);

	return $LoopTimeout unless @Timers;

	# convert time to an even number of milliseconds, adding 1
	# extra, otherwise floating point fun can occur and we'll
	# call RunTimers like 20-30 times, each returning a timeout
	# of 0.0000212 seconds
	my $timeout = int(($Timers[0][0] - $now) * 1000) + 1;

	# -1 is an infinite timeout, so prefer a real timeout
	($LoopTimeout < 0 || $LoopTimeout >= $timeout) ? $timeout : $LoopTimeout
}

sub sig_setmask { sigprocmask(SIG_SETMASK, @_) or die "sigprocmask: $!" }

sub block_signals () {
	my $oldset = POSIX::SigSet->new;
	my $newset = POSIX::SigSet->new;
	$newset->fillset or die "fillset: $!";
	sig_setmask($newset, $oldset);
	$oldset;
}

# We can't use waitpid(-1) safely here since it can hit ``, system(),
# and other things.  So we scan the $wait_pids list, which is hopefully
# not too big.  We keep $wait_pids small by not calling dwaitpid()
# until we've hit EOF when reading the stdout of the child.

sub reap_pids {
	$reap_armed = undef;
	my $tmp = $wait_pids or return;
	$wait_pids = undef;
	$Stack{reap_runq} = $tmp;
	my $oldset = block_signals();
	foreach my $ary (@$tmp) {
		my ($pid, $cb, $arg) = @$ary;
		my $ret = waitpid($pid, WNOHANG);
		if ($ret == 0) {
			push @$wait_pids, $ary; # autovivifies @$wait_pids
		} elsif ($ret == $pid) {
			if ($cb) {
				eval { $cb->($arg, $pid) };
				warn "E: dwaitpid($pid) in_loop: $@" if $@;
			}
		} else {
			warn "waitpid($pid, WNOHANG) = $ret, \$!=$!, \$?=$?";
		}
	}
	sig_setmask($oldset);
	delete $Stack{reap_runq};
}

# reentrant SIGCHLD handler (since reap_pids is not reentrant)
sub enqueue_reap () { $reap_armed //= requeue(\&reap_pids) }

sub in_loop () { $in_loop }

# Internal function: run the post-event callback, send read events
# for pushed-back data, and close pending connections.  returns 1
# if event loop should continue, or 0 to shut it all down.
sub PostEventLoop () {
	# now we can close sockets that wanted to close during our event
	# processing.  (we didn't want to close them during the loop, as we
	# didn't want fd numbers being reused and confused during the event
	# loop)
	if (my $close_now = $ToClose) {
		$ToClose = undef; # will be autovivified on push
		@$close_now = map { fileno($_) } @$close_now;

		# order matters, destroy expiry times, first:
		delete @$EXPMAP{@$close_now};

		# ->DESTROY methods may populate ToClose
		delete @DescriptorMap{@$close_now};
	}

	# by default we keep running, unless a postloop callback cancels it
	$PostLoopCallback ? $PostLoopCallback->(\%DescriptorMap) : 1;
}

sub EventLoop {
    $Epoll //= _InitPoller();
    local $in_loop = 1;
    my @events;
    do {
        my $timeout = RunTimers();

        # get up to 1000 events
        epoll_wait($Epoll, 1000, $timeout, \@events);
        for my $fd (@events) {
            # it's possible epoll_wait returned many events, including some at the end
            # that ones in the front triggered unregister-interest actions.  if we
            # can't find the %sock entry, it's because we're no longer interested
            # in that event.

	    # guard stack-not-refcounted w/ Carp + @DB::args
            my $obj = $DescriptorMap{$fd};
            $obj->event_step;
        }
    } while (PostEventLoop());
    _run_later();
}

=head2 C<< CLASS->SetPostLoopCallback( CODEREF ) >>

Sets post loop callback function.  Pass a subref and it will be
called every time the event loop finishes.

Return 1 (or any true value) from the sub to make the loop continue, 0 or false
and it will exit.

The callback function will be passed two parameters: \%DescriptorMap

=cut
sub SetPostLoopCallback {
    my ($class, $ref) = @_;

    # global callback
    $PostLoopCallback = (defined $ref && ref $ref eq 'CODE') ? $ref : undef;
}

#####################################################################
### PublicInbox::DS-the-object code
#####################################################################

=head2 OBJECT METHODS

=head2 C<< CLASS->new( $socket ) >>

Create a new PublicInbox::DS subclass object for the given I<socket> which will
react to events on it during the C<EventLoop>.

This is normally (always?) called from your subclass via:

  $class->SUPER::new($socket);

=cut
sub new {
    my ($self, $sock, $ev) = @_;
    $self->{sock} = $sock;
    my $fd = fileno($sock);

    $Epoll //= _InitPoller();
retry:
    if (epoll_ctl($Epoll, EPOLL_CTL_ADD, $fd, $ev)) {
        if ($! == EINVAL && ($ev & EPOLLEXCLUSIVE)) {
            $ev &= ~EPOLLEXCLUSIVE;
            goto retry;
        }
        die "EPOLL_CTL_ADD $self/$sock/$fd: $!";
    }
    croak("FD:$fd in use by $DescriptorMap{$fd} (for $self/$sock)")
        if defined($DescriptorMap{$fd});

    $DescriptorMap{$fd} = $self;
}


#####################################################################
### I N S T A N C E   M E T H O D S
#####################################################################

sub requeue ($) { push @$nextq, $_[0] } # autovivifies

=head2 C<< $obj->close >>

Close the socket.

=cut
sub close {
    my ($self) = @_;
    my $sock = delete $self->{sock} or return;

    # we need to flush our write buffer, as there may
    # be self-referential closures (sub { $client->close })
    # preventing the object from being destroyed
    delete $self->{wbuf};

    # if we're using epoll, we have to remove this from our epoll fd so we stop getting
    # notifications about it
    my $fd = fileno($sock);
    epoll_ctl($Epoll, EPOLL_CTL_DEL, $fd, 0) and
        croak("EPOLL_CTL_DEL($self/$sock): $!");

    # we explicitly don't delete from DescriptorMap here until we
    # actually close the socket, as we might be in the middle of
    # processing an epoll_wait/etc that returned hundreds of fds, one
    # of which is not yet processed and is what we're closing.  if we
    # keep it in DescriptorMap, then the event harnesses can just
    # looked at $pob->{sock} == undef and ignore it.  but if it's an
    # un-accounted for fd, then it (understandably) freak out a bit
    # and emit warnings, thinking their state got off.

    # defer closing the actual socket until the event loop is done
    # processing this round of events.  (otherwise we might reuse fds)
    push @$ToClose, $sock; # autovivifies $ToClose

    return 0;
}

# portable, non-thread-safe sendfile emulation (no pread, yet)
sub send_tmpio ($$) {
    my ($sock, $tmpio) = @_;

    sysseek($tmpio->[0], $tmpio->[1], SEEK_SET) or return;
    my $n = $tmpio->[2] // 65536;
    $n = 65536 if $n > 65536;
    defined(my $to_write = sysread($tmpio->[0], my $buf, $n)) or return;
    my $written = 0;
    while ($to_write > 0) {
        if (defined(my $w = syswrite($sock, $buf, $to_write, $written))) {
            $written += $w;
            $to_write -= $w;
        } else {
            return if $written == 0;
            last;
        }
    }
    $tmpio->[1] += $written; # offset
    $tmpio->[2] -= $written if defined($tmpio->[2]); # length
    $written;
}

sub epbit ($$) { # (sock, default)
	$_[0]->can('stop_SSL') ? PublicInbox::TLS::epollbit() : $_[1];
}

# returns 1 if done, 0 if incomplete
sub flush_write ($) {
    my ($self) = @_;
    my $sock = $self->{sock} or return;
    my $wbuf = $self->{wbuf} or return 1;

next_buf:
    while (my $bref = $wbuf->[0]) {
        if (ref($bref) ne 'CODE') {
            while ($sock) {
                my $w = send_tmpio($sock, $bref); # bref is tmpio
                if (defined $w) {
                    if ($w == 0) {
                        shift @$wbuf;
                        goto next_buf;
                    }
                } elsif ($! == EAGAIN) {
                    my $ev = epbit($sock, EPOLLOUT) or return $self->close;
                    epwait($sock, $ev | EPOLLONESHOT);
                    return 0;
                } else {
                    return $self->close;
                }
            }
        } else { #(ref($bref) eq 'CODE') {
            shift @$wbuf;
            my $before = scalar(@$wbuf);
            $bref->($self);

            # bref may be enqueueing more CODE to call (see accept_tls_step)
            return 0 if (scalar(@$wbuf) > $before);
        }
    } # while @$wbuf

    delete $self->{wbuf};
    1; # all done
}

sub rbuf_idle ($$) {
    my ($self, $rbuf) = @_;
    if ($$rbuf eq '') { # who knows how long till we can read again
        delete $self->{rbuf};
    } else {
        $self->{rbuf} = $rbuf;
    }
}

sub do_read ($$$;$) {
    my ($self, $rbuf, $len, $off) = @_;
    my $r = sysread(my $sock = $self->{sock}, $$rbuf, $len, $off // 0);
    return ($r == 0 ? $self->close : $r) if defined $r;
    # common for clients to break connections without warning,
    # would be too noisy to log here:
    if ($! == EAGAIN) {
        my $ev = epbit($sock, EPOLLIN) or return $self->close;
        epwait($sock, $ev | EPOLLONESHOT);
        rbuf_idle($self, $rbuf);
        0;
    } else {
        $self->close;
    }
}

# drop the socket if we hit unrecoverable errors on our system which
# require BOFH attention: ENOSPC, EFBIG, EIO, EMFILE, ENFILE...
sub drop {
    my $self = shift;
    carp(@_);
    $self->close;
}

# n.b.: use ->write/->read for this buffer to allow compatibility with
# PerlIO::mmap or PerlIO::scalar if needed
sub tmpio ($$$) {
	my ($self, $bref, $off) = @_;
	my $fh = tmpfile('wbuf', $self->{sock}, O_APPEND) or
		return drop($self, "tmpfile $!");
	$fh->autoflush(1);
	my $len = length($$bref) - $off;
	print $fh substr($$bref, $off, $len) or
		return drop($self, "write ($len): $!");
	[ $fh, 0 ] # [1] = offset, [2] = length, not set by us
}

=head2 C<< $obj->write( $data ) >>

Write the specified data to the underlying handle.  I<data> may be scalar,
scalar ref, code ref (to run when there).
Returns 1 if writes all went through, or 0 if there are writes in queue. If
it returns 1, caller should stop waiting for 'writable' events)

=cut
sub write {
    my ($self, $data) = @_;

    # nobody should be writing to closed sockets, but caller code can
    # do two writes within an event, have the first fail and
    # disconnect the other side (whose destructor then closes the
    # calling object, but it's still in a method), and then the
    # now-dead object does its second write.  that is this case.  we
    # just lie and say it worked.  it'll be dead soon and won't be
    # hurt by this lie.
    my $sock = $self->{sock} or return 1;
    my $ref = ref $data;
    my $bref = $ref ? $data : \$data;
    my $wbuf = $self->{wbuf};
    if ($wbuf && scalar(@$wbuf)) { # already buffering, can't write more...
        if ($ref eq 'CODE') {
            push @$wbuf, $bref;
        } else {
            my $tmpio = $wbuf->[-1];
            if ($tmpio && !defined($tmpio->[2])) { # append to tmp file buffer
                $tmpio->[0]->print($$bref) or return drop($self, "print: $!");
            } else {
                my $tmpio = tmpio($self, $bref, 0) or return 0;
                push @$wbuf, $tmpio;
            }
        }
        return 0;
    } elsif ($ref eq 'CODE') {
        $bref->($self);
        return 1;
    } else {
        my $to_write = length($$bref);
        my $written = syswrite($sock, $$bref, $to_write);

        if (defined $written) {
            return 1 if $written == $to_write;
            requeue($self); # runs: event_step -> flush_write
        } elsif ($! == EAGAIN) {
            my $ev = epbit($sock, EPOLLOUT) or return $self->close;
            epwait($sock, $ev | EPOLLONESHOT);
            $written = 0;
        } else {
            return $self->close;
        }

        # deal with EAGAIN or partial write:
        my $tmpio = tmpio($self, $bref, $written) or return 0;

        # wbuf may be an empty array if we're being called inside
        # ->flush_write via CODE bref:
        push @{$self->{wbuf}}, $tmpio; # autovivifies
        return 0;
    }
}

use constant MSG_MORE => ($^O eq 'linux') ? 0x8000 : 0;

sub msg_more ($$) {
    my $self = $_[0];
    my $sock = $self->{sock} or return 1;
    my $wbuf = $self->{wbuf};

    if (MSG_MORE && (!defined($wbuf) || !scalar(@$wbuf)) &&
		!$sock->can('stop_SSL')) {
        my $n = send($sock, $_[1], MSG_MORE);
        if (defined $n) {
            my $nlen = length($_[1]) - $n;
            return 1 if $nlen == 0; # all done!
            # queue up the unwritten substring:
            my $tmpio = tmpio($self, \($_[1]), $n) or return 0;
            push @{$self->{wbuf}}, $tmpio; # autovivifies
            epwait($sock, EPOLLOUT|EPOLLONESHOT);
            return 0;
        }
    }

    # don't redispatch into NNTPdeflate::write
    PublicInbox::DS::write($self, \($_[1]));
}

sub epwait ($$) {
    my ($sock, $ev) = @_;
    epoll_ctl($Epoll, EPOLL_CTL_MOD, fileno($sock), $ev) and
        croak("EPOLL_CTL_MOD($sock): $!");
}

# return true if complete, false if incomplete (or failure)
sub accept_tls_step ($) {
    my ($self) = @_;
    my $sock = $self->{sock} or return;
    return 1 if $sock->accept_SSL;
    return $self->close if $! != EAGAIN;
    my $ev = PublicInbox::TLS::epollbit() or return $self->close;
    epwait($sock, $ev | EPOLLONESHOT);
    unshift(@{$self->{wbuf}}, \&accept_tls_step); # autovivifies
    0;
}

# return true if complete, false if incomplete (or failure)
sub shutdn_tls_step ($) {
    my ($self) = @_;
    my $sock = $self->{sock} or return;
    return $self->close if $sock->stop_SSL(SSL_fast_shutdown => 1);
    return $self->close if $! != EAGAIN;
    my $ev = PublicInbox::TLS::epollbit() or return $self->close;
    epwait($sock, $ev | EPOLLONESHOT);
    unshift(@{$self->{wbuf}}, \&shutdn_tls_step); # autovivifies
    0;
}

# don't bother with shutdown($sock, 2), we don't fork+exec w/o CLOEXEC
# or fork w/o exec, so no inadvertent socket sharing
sub shutdn ($) {
    my ($self) = @_;
    my $sock = $self->{sock} or return;
    if ($sock->can('stop_SSL')) {
        shutdn_tls_step($self);
    } else {
	$self->close;
    }
}

sub dwaitpid ($;$$) {
	my ($pid, $cb, $arg) = @_;
	if ($in_loop) {
		push @$wait_pids, [ $pid, $cb, $arg ];
		# We could've just missed our SIGCHLD, cover it, here:
		enqueue_reap();
	} else {
		my $ret = waitpid($pid, 0);
		if ($ret == $pid) {
			if ($cb) {
				eval { $cb->($arg, $pid) };
				carp "E: dwaitpid($pid) !in_loop: $@" if $@;
			}
		} else {
			carp "waitpid($pid, 0) = $ret, \$!=$!, \$?=$?";
		}
	}
}

sub _run_later () {
	my $q = $later_q or return;
	$later_q = undef;
	$Stack{later_q} = $q;
	$_->() for @$q;
	delete $Stack{later_q};
}

sub later ($) {
	push @$later_q, $_[0]; # autovivifies @$later_q
	add_uniq_timer('later', 60, \&_run_later);
}

sub expire_old () {
	my $cur = $EXPMAP or return;
	$EXPMAP = undef;
	my $old = now() - $EXPTIME;
	while (my ($fd, $idle_at) = each %$cur) {
		if ($idle_at < $old) {
			my $ds_obj = $DescriptorMap{$fd};
			$EXPMAP->{$fd} = $idle_at if !$ds_obj->shutdn;
		} else {
			$EXPMAP->{$fd} = $idle_at;
		}
	}
	add_uniq_timer('expire', 60, \&expire_old) if $EXPMAP;
}

sub update_idle_time {
	my ($self) = @_;
	my $sock = $self->{sock} or return;
	$EXPMAP->{fileno($sock)} = now();
	add_uniq_timer('expire', 60, \&expire_old);
}

sub not_idle_long {
	my ($self, $now) = @_;
	my $sock = $self->{sock} or return;
	my $idle_at = $EXPMAP->{fileno($sock)} or return;
	($idle_at + $EXPTIME) > $now;
}

1;

=head1 AUTHORS (Danga::Socket)

Brad Fitzpatrick <brad@danga.com> - author

Michael Granger <ged@danga.com> - docs, testing

Mark Smith <junior@danga.com> - contributor, heavy user, testing

Matt Sergeant <matt@sergeant.org> - kqueue support, docs, timers, other bits
