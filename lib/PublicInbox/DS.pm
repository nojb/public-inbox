# This library is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.
#
# This license differs from the rest of public-inbox
#
# This is a fork of the (for now) unmaintained Danga::Socket 1.61.
# Unused features will be removed, and updates will be made to take
# advantage of newer kernels.
#
# API changes to diverge from Danga::Socket will happen to better
# accomodate new features and improve scalability.  Do not expect
# this to be a stable API like Danga::Socket.
# Bugs encountered (and likely fixed) are reported to
# bug-Danga-Socket@rt.cpan.org and visible at:
# https://rt.cpan.org/Public/Dist/Display.html?Name=Danga-Socket
package PublicInbox::DS;
use strict;
use bytes;
use POSIX ();
use IO::Handle qw();
use Fcntl qw(FD_CLOEXEC F_SETFD F_GETFD);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
use parent qw(Exporter);
our @EXPORT_OK = qw(now);
use warnings;

use PublicInbox::Syscall qw(:epoll);

use fields ('sock',              # underlying socket
            'wbuf',              # arrayref of scalars, scalarrefs, or coderefs to write
            'wbuf_off',  # offset into first element of wbuf to start writing at
            'event_watch',       # bitmask of events the client is interested in (POLLIN,OUT,etc.)
            );

use Errno  qw(EAGAIN EINVAL);
use Carp   qw(croak confess);

use constant POLLIN        => 1;
use constant POLLOUT       => 4;
use constant POLLERR       => 8;
use constant POLLHUP       => 16;
use constant POLLNVAL      => 32;

our $HAVE_KQUEUE = eval { require IO::KQueue; 1 };

our (
     $HaveEpoll,                 # Flag -- is epoll available?  initially undefined.
     $HaveKQueue,
     %DescriptorMap,             # fd (num) -> PublicInbox::DS object
     $Epoll,                     # Global epoll fd (for epoll mode only)
     $KQueue,                    # Global kqueue fd ref (for kqueue mode only)
     $_io,                       # IO::Handle for Epoll
     @ToClose,                   # sockets to close when event loop is done

     $PostLoopCallback,          # subref to call at the end of each loop, if defined (global)

     $LoopTimeout,               # timeout of event loop in milliseconds
     $DoneInit,                  # if we've done the one-time module init yet
     @Timers,                    # timers
     );

# this may be set to zero with old kernels
our $EPOLLEXCLUSIVE = EPOLLEXCLUSIVE;
Reset();

#####################################################################
### C L A S S   M E T H O D S
#####################################################################

=head2 C<< CLASS->Reset() >>

Reset all state

=cut
sub Reset {
    %DescriptorMap = ();
    @ToClose = ();
    $LoopTimeout = -1;  # no timeout by default
    @Timers = ();

    $PostLoopCallback = undef;
    $DoneInit = 0;

    # NOTE kqueue is close-on-fork, and we don't account for it, yet
    # OTOH, we (public-inbox) don't need this sub outside of tests...
    POSIX::close($$KQueue) if !$_io && $KQueue && $$KQueue >= 0;
    $KQueue = undef;

    $_io = undef; # close $Epoll
    $Epoll = undef;

    *EventLoop = *FirstTimeEventLoop;
}

=head2 C<< CLASS->SetLoopTimeout( $timeout ) >>

Set the loop timeout for the event loop to some value in milliseconds.

A timeout of 0 (zero) means poll forever. A timeout of -1 means poll and return
immediately.

=cut
sub SetLoopTimeout {
    return $LoopTimeout = $_[1] + 0;
}

=head2 C<< CLASS->AddTimer( $seconds, $coderef ) >>

Add a timer to occur $seconds from now. $seconds may be fractional, but timers
are not guaranteed to fire at the exact time you ask for.

Returns a timer object which you can call C<< $timer->cancel >> on if you need to.

=cut
sub AddTimer {
    my ($class, $secs, $coderef) = @_;

    if (!$secs) {
        my $timer = bless([0, $coderef], 'PublicInbox::DS::Timer');
        unshift(@Timers, $timer);
        return $timer;
    }

    my $fire_time = now() + $secs;

    my $timer = bless [$fire_time, $coderef], "PublicInbox::DS::Timer";

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

# keeping this around in case we support other FD types for now,
# epoll_create1(EPOLL_CLOEXEC) requires Linux 2.6.27+...
sub set_cloexec ($) {
    my ($fd) = @_;

    $_io = IO::Handle->new_from_fd($fd, 'r+') or return;
    defined(my $fl = fcntl($_io, F_GETFD, 0)) or return;
    fcntl($_io, F_SETFD, $fl | FD_CLOEXEC);
}

sub _InitPoller
{
    return if $DoneInit;
    $DoneInit = 1;

    if ($HAVE_KQUEUE) {
        $KQueue = IO::KQueue->new();
        $HaveKQueue = defined $KQueue;
        if ($HaveKQueue) {
            *EventLoop = *KQueueEventLoop;
        }
    }
    elsif (PublicInbox::Syscall::epoll_defined()) {
        $Epoll = eval { epoll_create(1024); };
        $HaveEpoll = defined $Epoll && $Epoll >= 0;
        if ($HaveEpoll) {
            set_cloexec($Epoll);
            *EventLoop = *EpollEventLoop;
        }
    }

    if (!$HaveEpoll && !$HaveKQueue) {
        require IO::Poll;
        *EventLoop = *PollEventLoop;
    }
}

=head2 C<< CLASS->EventLoop() >>

Start processing IO events. In most daemon programs this never exits. See
C<PostLoopCallback> below for how to exit the loop.

=cut
sub FirstTimeEventLoop {
    my $class = shift;

    _InitPoller();

    if ($HaveEpoll) {
        EpollEventLoop($class);
    } elsif ($HaveKQueue) {
        KQueueEventLoop($class);
    } else {
        PollEventLoop($class);
    }
}

sub now () { clock_gettime(CLOCK_MONOTONIC) }

# runs timers and returns milliseconds for next one, or next event loop
sub RunTimers {
    return $LoopTimeout unless @Timers;

    my $now = now();

    # Run expired timers
    while (@Timers && $Timers[0][0] <= $now) {
        my $to_run = shift(@Timers);
        $to_run->[1]->($now) if $to_run->[1];
    }

    return $LoopTimeout unless @Timers;

    # convert time to an even number of milliseconds, adding 1
    # extra, otherwise floating point fun can occur and we'll
    # call RunTimers like 20-30 times, each returning a timeout
    # of 0.0000212 seconds
    my $timeout = int(($Timers[0][0] - $now) * 1000) + 1;

    # -1 is an infinite timeout, so prefer a real timeout
    return $timeout     if $LoopTimeout == -1;

    # otherwise pick the lower of our regular timeout and time until
    # the next timer
    return $LoopTimeout if $LoopTimeout < $timeout;
    return $timeout;
}

### The epoll-based event loop. Gets installed as EventLoop if IO::Epoll loads
### okay.
sub EpollEventLoop {
    my $class = shift;

    while (1) {
        my @events;
        my $i;
        my $timeout = RunTimers();

        # get up to 1000 events
        my $evcount = epoll_wait($Epoll, 1000, $timeout, \@events);
        for ($i=0; $i<$evcount; $i++) {
            # it's possible epoll_wait returned many events, including some at the end
            # that ones in the front triggered unregister-interest actions.  if we
            # can't find the %sock entry, it's because we're no longer interested
            # in that event.
            $DescriptorMap{$events[$i]->[0]}->event_step;
        }
        return unless PostEventLoop();
    }
    exit 0;
}

### The fallback IO::Poll-based event loop. Gets installed as EventLoop if
### IO::Epoll fails to load.
sub PollEventLoop {
    my $class = shift;

    my PublicInbox::DS $pob;

    while (1) {
        my $timeout = RunTimers();

        # the following sets up @poll as a series of ($poll,$event_mask)
        # items, then uses IO::Poll::_poll, implemented in XS, which
        # modifies the array in place with the even elements being
        # replaced with the event masks that occured.
        my @poll;
        while ( my ($fd, $sock) = each %DescriptorMap ) {
            push @poll, $fd, $sock->{event_watch};
        }

        # if nothing to poll, either end immediately (if no timeout)
        # or just keep calling the callback
        unless (@poll) {
            select undef, undef, undef, ($timeout / 1000);
            return unless PostEventLoop();
            next;
        }

        my $count = IO::Poll::_poll($timeout, @poll);
        unless ($count >= 0) {
            return unless PostEventLoop();
            next;
        }

        # Fetch handles with read events
        while (@poll) {
            my ($fd, $state) = splice(@poll, 0, 2);
            $DescriptorMap{$fd}->event_step if $state;
        }

        return unless PostEventLoop();
    }

    exit 0;
}

### The kqueue-based event loop. Gets installed as EventLoop if IO::KQueue works
### okay.
sub KQueueEventLoop {
    my $class = shift;

    while (1) {
        my $timeout = RunTimers();
        my @ret = eval { $KQueue->kevent($timeout) };
        if (my $err = $@) {
            # workaround https://rt.cpan.org/Ticket/Display.html?id=116615
            if ($err =~ /Interrupted system call/) {
                @ret = ();
            } else {
                die $err;
            }
        }

        foreach my $kev (@ret) {
            $DescriptorMap{$kev->[0]}->event_step;
        }
        return unless PostEventLoop();
    }

    exit(0);
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

# Internal function: run the post-event callback, send read events
# for pushed-back data, and close pending connections.  returns 1
# if event loop should continue, or 0 to shut it all down.
sub PostEventLoop {
    # now we can close sockets that wanted to close during our event processing.
    # (we didn't want to close them during the loop, as we didn't want fd numbers
    #  being reused and confused during the event loop)
    while (my $sock = shift @ToClose) {
        my $fd = fileno($sock);

        # close the socket.  (not a PublicInbox::DS close)
        $sock->close;

        # and now we can finally remove the fd from the map.  see
        # comment above in ->close.
        delete $DescriptorMap{$fd};
    }


    # by default we keep running, unless a postloop callback (either per-object
    # or global) cancels it
    my $keep_running = 1;

    # now we're at the very end, call callback if defined
    if (defined $PostLoopCallback) {
        $keep_running &&= $PostLoopCallback->(\%DescriptorMap);
    }

    return $keep_running;
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
    my ($self, $sock, $exclusive) = @_;
    $self = fields::new($self) unless ref $self;

    $self->{sock} = $sock;
    my $fd = fileno($sock);

    Carp::cluck("undef sock and/or fd in PublicInbox::DS->new.  sock=" . ($sock || "") . ", fd=" . ($fd || ""))
        unless $sock && $fd;

    $self->{wbuf} = [];

    my $ev = $self->{event_watch} = POLLERR|POLLHUP|POLLNVAL;

    _InitPoller();

    if ($HaveEpoll) {
        if ($exclusive) {
            $ev = $self->{event_watch} = EPOLLIN|EPOLLERR|EPOLLHUP|$EPOLLEXCLUSIVE;
        }
retry:
        if (epoll_ctl($Epoll, EPOLL_CTL_ADD, $fd, $ev)) {
            if ($! == EINVAL && ($ev & $EPOLLEXCLUSIVE)) {
                $EPOLLEXCLUSIVE = 0; # old kernel
                $ev = $self->{event_watch} = EPOLLIN|EPOLLERR|EPOLLHUP;
                goto retry;
            }
            die "couldn't add epoll watch for $fd: $!\n";
        }
    }
    elsif ($HaveKQueue) {
        # Add them to the queue but disabled for now
        $KQueue->EV_SET($fd, IO::KQueue::EVFILT_READ(),
                        IO::KQueue::EV_ADD() | IO::KQueue::EV_DISABLE());
        $KQueue->EV_SET($fd, IO::KQueue::EVFILT_WRITE(),
                        IO::KQueue::EV_ADD() | IO::KQueue::EV_DISABLE());
    }

    Carp::cluck("PublicInbox::DS::new blowing away existing descriptor map for fd=$fd ($DescriptorMap{$fd})")
        if $DescriptorMap{$fd};

    $DescriptorMap{$fd} = $self;
    return $self;
}


#####################################################################
### I N S T A N C E   M E T H O D S
#####################################################################

=head2 C<< $obj->close >>

Close the socket.

=cut
sub close {
    my ($self) = @_;
    my $sock = delete $self->{sock} or return;

    # we need to flush our write buffer, as there may
    # be self-referential closures (sub { $client->close })
    # preventing the object from being destroyed
    @{$self->{wbuf}} = ();

    # if we're using epoll, we have to remove this from our epoll fd so we stop getting
    # notifications about it
    if ($HaveEpoll) {
        my $fd = fileno($sock);
        epoll_ctl($Epoll, EPOLL_CTL_DEL, $fd, $self->{event_watch}) and
            confess("EPOLL_CTL_DEL: $!");
    }

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
    push @ToClose, $sock;

    return 0;
}

# returns 1 if done, 0 if incomplete
sub flush_write ($) {
    my ($self) = @_;
    my $sock = $self->{sock} or return 1;
    my $wbuf = $self->{wbuf};

    while (my $bref = $wbuf->[0]) {
        my $ref = ref($bref);
        if ($ref eq 'SCALAR') {
            my $len = bytes::length($$bref);
            my $off = $self->{wbuf_off} || 0;
            my $to_write = $len - $off;
            my $written = syswrite($sock, $$bref, $to_write, $off);
            if (defined $written) {
                if ($written == $to_write) {
                    shift @$wbuf;
                } else {
                    $self->{wbuf_off} = $off + $written;
                }
                next; # keep going until EAGAIN
            } elsif ($! == EAGAIN) {
                $self->watch_write(1);
            } else {
                $self->close;
            }
            return 0;
        } else { #($ref eq 'CODE') {
            shift @$wbuf;
            $bref->();
        }
    } # while @$wbuf

    $self->watch_write(0);
    1; # all done
}

=head2 C<< $obj->write( $data ) >>

Write the specified data to the underlying handle.  I<data> may be scalar,
scalar ref, code ref (to run when there), or undef just to kick-start.
Returns 1 if writes all went through, or 0 if there are writes in queue. If
it returns 1, caller should stop waiting for 'writable' events)

=cut
sub write {
    my ($self, $data) = @_;
    return flush_write($self) unless defined $data;

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
    if (@$wbuf) { # already buffering, can't write more...
        push @$wbuf, $bref;
        return 0;
    } elsif ($ref eq 'CODE') {
        $bref->();
        return 1;
    } else {
        my $to_write = bytes::length($$bref);
        my $written = syswrite($sock, $$bref, $to_write);

        if (defined $written) {
            return 1 if $written == $to_write;
            $self->{wbuf_off} = $written;
            push @$wbuf, $bref;
            return flush_write($self); # try until EAGAIN
        } elsif ($! == EAGAIN) {
            push @$wbuf, $bref;
            $self->watch_write(1);
        } else {
            $self->close;
        }
        return 0;
    }
}

=head2 C<< $obj->watch_read( $boolean ) >>

Turn 'readable' event notification on or off.

=cut
sub watch_read {
    my PublicInbox::DS $self = shift;
    my $sock = $self->{sock} or return;

    my $val = shift;
    my $event = $self->{event_watch};

    $event &= ~POLLIN if ! $val;
    $event |=  POLLIN if   $val;

    my $fd = fileno($sock);
    # If it changed, set it
    if ($event != $self->{event_watch}) {
        if ($HaveKQueue) {
            $KQueue->EV_SET($fd, IO::KQueue::EVFILT_READ(),
                            $val ? IO::KQueue::EV_ENABLE() : IO::KQueue::EV_DISABLE());
        }
        elsif ($HaveEpoll) {
            epoll_ctl($Epoll, EPOLL_CTL_MOD, $fd, $event) and
                confess("EPOLL_CTL_MOD: $!");
        }
        $self->{event_watch} = $event;
    }
}

=head2 C<< $obj->watch_write( $boolean ) >>

Turn 'writable' event notification on or off.

=cut
sub watch_write {
    my PublicInbox::DS $self = shift;
    my $sock = $self->{sock} or return;

    my $val = shift;
    my $event = $self->{event_watch};

    $event &= ~POLLOUT if ! $val;
    $event |=  POLLOUT if   $val;
    my $fd = fileno($sock);

    # If it changed, set it
    if ($event != $self->{event_watch}) {
        if ($HaveKQueue) {
            $KQueue->EV_SET($fd, IO::KQueue::EVFILT_WRITE(),
                            $val ? IO::KQueue::EV_ENABLE() : IO::KQueue::EV_DISABLE());
        }
        elsif ($HaveEpoll) {
            epoll_ctl($Epoll, EPOLL_CTL_MOD, $fd, $event) and
                    confess "EPOLL_CTL_MOD: $!";
        }
        $self->{event_watch} = $event;
    }
}

package PublicInbox::DS::Timer;
# [$abs_float_firetime, $coderef];
sub cancel {
    $_[0][1] = undef;
}

1;

=head1 AUTHORS (Danga::Socket)

Brad Fitzpatrick <brad@danga.com> - author

Michael Granger <ged@danga.com> - docs, testing

Mark Smith <junior@danga.com> - contributor, heavy user, testing

Matt Sergeant <matt@sergeant.org> - kqueue support, docs, timers, other bits
