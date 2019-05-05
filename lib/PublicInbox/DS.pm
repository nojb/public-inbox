# This library is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.
#
# This license differs from the rest of public-inbox
#
# This is a fork of the (for now) unmaintained Danga::Socket 1.61.
# Unused features will be removed, and updates will be made to take
# advantage of newer kernels

package PublicInbox::DS;
use strict;
use bytes;
use POSIX ();
use Time::HiRes ();

use vars qw{$VERSION};
$VERSION = "1.61";

use warnings;
no  warnings qw(deprecated);

use PublicInbox::Syscall qw(:epoll);

use fields ('sock',              # underlying socket
            'fd',                # numeric file descriptor
            'write_buf',         # arrayref of scalars, scalarrefs, or coderefs to write
            'write_buf_offset',  # offset into first array of write_buf to start writing at
            'write_buf_size',    # total length of data in all write_buf items
            'write_set_watch',   # bool: true if we internally set watch_write rather than by a subclass
            'closed',            # bool: socket is closed
            'event_watch',       # bitmask of events the client is interested in (POLLIN,OUT,etc.)
            'writer_func',       # subref which does writing.  must return bytes written (or undef) and set $! on errors
            );

use Errno  qw(EINPROGRESS EWOULDBLOCK EISCONN ENOTSOCK
              EPIPE EAGAIN EBADF ECONNRESET ENOPROTOOPT);
use Socket qw(IPPROTO_TCP);
use Carp   qw(croak confess);

use constant DebugLevel => 0;

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
     $KQueue,                    # Global kqueue fd (for kqueue mode only)
     @ToClose,                   # sockets to close when event loop is done
     %OtherFds,                  # A hash of "other" (non-PublicInbox::DS) file
                                 # descriptors for the event loop to track.

     $PostLoopCallback,          # subref to call at the end of each loop, if defined (global)
     %PLCMap,                    # fd (num) -> PostLoopCallback (per-object)

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
    %OtherFds = ();
    $LoopTimeout = -1;  # no timeout by default
    @Timers = ();

    $PostLoopCallback = undef;
    %PLCMap = ();
    $DoneInit = 0;

    POSIX::close($Epoll)  if defined $Epoll  && $Epoll  >= 0;
    POSIX::close($KQueue) if defined $KQueue && $KQueue >= 0;

    *EventLoop = *FirstTimeEventLoop;
}

=head2 C<< CLASS->HaveEpoll() >>

Returns a true value if this class will use IO::Epoll for async IO.

=cut
sub HaveEpoll {
    _InitPoller();
    return $HaveEpoll;
}

=head2 C<< CLASS->WatchedSockets() >>

Returns the number of file descriptors which are registered with the global
poll object.

=cut
sub WatchedSockets {
    return scalar keys %DescriptorMap;
}
*watched_sockets = *WatchedSockets;

=head2 C<< CLASS->ToClose() >>

Return the list of sockets that are awaiting close() at the end of the
current event loop.

=cut
sub ToClose { return @ToClose; }

=head2 C<< CLASS->OtherFds( [%fdmap] ) >>

Get/set the hash of file descriptors that need processing in parallel with
the registered PublicInbox::DS objects.

=cut
sub OtherFds {
    my $class = shift;
    if ( @_ ) { %OtherFds = @_ }
    return wantarray ? %OtherFds : \%OtherFds;
}

=head2 C<< CLASS->AddOtherFds( [%fdmap] ) >>

Add fds to the OtherFds hash for processing.

=cut
sub AddOtherFds {
    my $class = shift;
    %OtherFds = ( %OtherFds, @_ ); # FIXME investigate what happens on dupe fds
    return wantarray ? %OtherFds : \%OtherFds;
}

=head2 C<< CLASS->SetLoopTimeout( $timeout ) >>

Set the loop timeout for the event loop to some value in milliseconds.

A timeout of 0 (zero) means poll forever. A timeout of -1 means poll and return
immediately.

=cut
sub SetLoopTimeout {
    return $LoopTimeout = $_[1] + 0;
}

=head2 C<< CLASS->DebugMsg( $format, @args ) >>

Print the debugging message specified by the C<sprintf>-style I<format> and
I<args>

=cut
sub DebugMsg {
    my ( $class, $fmt, @args ) = @_;
    chomp $fmt;
    printf STDERR ">>> $fmt\n", @args;
}

=head2 C<< CLASS->AddTimer( $seconds, $coderef ) >>

Add a timer to occur $seconds from now. $seconds may be fractional, but timers
are not guaranteed to fire at the exact time you ask for.

Returns a timer object which you can call C<< $timer->cancel >> on if you need to.

=cut
sub AddTimer {
    my $class = shift;
    my ($secs, $coderef) = @_;

    my $fire_time = Time::HiRes::time() + $secs;

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

=head2 C<< CLASS->DescriptorMap() >>

Get the hash of PublicInbox::DS objects keyed by the file descriptor (fileno) they
are wrapping.

Returns a hash in list context or a hashref in scalar context.

=cut
sub DescriptorMap {
    return wantarray ? %DescriptorMap : \%DescriptorMap;
}
*descriptor_map = *DescriptorMap;
*get_sock_ref = *DescriptorMap;

sub _InitPoller
{
    return if $DoneInit;
    $DoneInit = 1;

    if ($HAVE_KQUEUE) {
        $KQueue = IO::KQueue->new();
        $HaveKQueue = $KQueue >= 0;
        if ($HaveKQueue) {
            *EventLoop = *KQueueEventLoop;
        }
    }
    elsif (PublicInbox::Syscall::epoll_defined()) {
        $Epoll = eval { epoll_create(1024); };
        $HaveEpoll = defined $Epoll && $Epoll >= 0;
        if ($HaveEpoll) {
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

# runs timers and returns milliseconds for next one, or next event loop
sub RunTimers {
    return $LoopTimeout unless @Timers;

    my $now = Time::HiRes::time();

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

    foreach my $fd ( keys %OtherFds ) {
        if (epoll_ctl($Epoll, EPOLL_CTL_ADD, $fd, EPOLLIN) == -1) {
            warn "epoll_ctl(): failure adding fd=$fd; $! (", $!+0, ")\n";
        }
    }

    while (1) {
        my @events;
        my $i;
        my $timeout = RunTimers();

        # get up to 1000 events
        my $evcount = epoll_wait($Epoll, 1000, $timeout, \@events);
      EVENT:
        for ($i=0; $i<$evcount; $i++) {
            my $ev = $events[$i];

            # it's possible epoll_wait returned many events, including some at the end
            # that ones in the front triggered unregister-interest actions.  if we
            # can't find the %sock entry, it's because we're no longer interested
            # in that event.
            my PublicInbox::DS $pob = $DescriptorMap{$ev->[0]};
            my $code;
            my $state = $ev->[1];

            # if we didn't find a Perlbal::Socket subclass for that fd, try other
            # pseudo-registered (above) fds.
            if (! $pob) {
                if (my $code = $OtherFds{$ev->[0]}) {
                    $code->($state);
                } else {
                    my $fd = $ev->[0];
                    warn "epoll() returned fd $fd w/ state $state for which we have no mapping.  removing.\n";
                    POSIX::close($fd);
                    epoll_ctl($Epoll, EPOLL_CTL_DEL, $fd, 0);
                }
                next;
            }

            DebugLevel >= 1 && $class->DebugMsg("Event: fd=%d (%s), state=%d \@ %s\n",
                                                $ev->[0], ref($pob), $ev->[1], time);

            # standard non-profiling codepat
            $pob->event_read   if $state & EPOLLIN && ! $pob->{closed};
            $pob->event_write  if $state & EPOLLOUT && ! $pob->{closed};
            if ($state & (EPOLLERR|EPOLLHUP)) {
                $pob->event_err    if $state & EPOLLERR && ! $pob->{closed};
                $pob->event_hup    if $state & EPOLLHUP && ! $pob->{closed};
            }
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
        foreach my $fd ( keys %OtherFds ) {
            push @poll, $fd, POLLIN;
        }
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
        unless ($count) {
            return unless PostEventLoop();
            next;
        }

        # Fetch handles with read events
        while (@poll) {
            my ($fd, $state) = splice(@poll, 0, 2);
            next unless $state;

            $pob = $DescriptorMap{$fd};

            if (!$pob) {
                if (my $code = $OtherFds{$fd}) {
                    $code->($state);
                }
                next;
            }

            $pob->event_read   if $state & POLLIN && ! $pob->{closed};
            $pob->event_write  if $state & POLLOUT && ! $pob->{closed};
            $pob->event_err    if $state & POLLERR && ! $pob->{closed};
            $pob->event_hup    if $state & POLLHUP && ! $pob->{closed};
        }

        return unless PostEventLoop();
    }

    exit 0;
}

### The kqueue-based event loop. Gets installed as EventLoop if IO::KQueue works
### okay.
sub KQueueEventLoop {
    my $class = shift;

    foreach my $fd (keys %OtherFds) {
        $KQueue->EV_SET($fd, IO::KQueue::EVFILT_READ(), IO::KQueue::EV_ADD());
    }

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
            my ($fd, $filter, $flags, $fflags) = @$kev;
            my PublicInbox::DS $pob = $DescriptorMap{$fd};
            if (!$pob) {
                if (my $code = $OtherFds{$fd}) {
                    $code->($filter);
                }  else {
                    warn "kevent() returned fd $fd for which we have no mapping.  removing.\n";
                    POSIX::close($fd); # close deletes the kevent entry
                }
                next;
            }

            DebugLevel >= 1 && $class->DebugMsg("Event: fd=%d (%s), flags=%d \@ %s\n",
                                                        $fd, ref($pob), $flags, time);

            $pob->event_read  if $filter == IO::KQueue::EVFILT_READ()  && !$pob->{closed};
            $pob->event_write if $filter == IO::KQueue::EVFILT_WRITE() && !$pob->{closed};
            if ($flags ==  IO::KQueue::EV_EOF() && !$pob->{closed}) {
                if ($fflags) {
                    $pob->event_err;
                } else {
                    $pob->event_hup;
                }
            }
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

The callback function will be passed two parameters: \%DescriptorMap, \%OtherFds.

=cut
sub SetPostLoopCallback {
    my ($class, $ref) = @_;

    if (ref $class) {
        # per-object callback
        my PublicInbox::DS $self = $class;
        if (defined $ref && ref $ref eq 'CODE') {
            $PLCMap{$self->{fd}} = $ref;
        } else {
            delete $PLCMap{$self->{fd}};
        }
    } else {
        # global callback
        $PostLoopCallback = (defined $ref && ref $ref eq 'CODE') ? $ref : undef;
    }
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
        # comment above in _cleanup.
        delete $DescriptorMap{$fd};
    }


    # by default we keep running, unless a postloop callback (either per-object
    # or global) cancels it
    my $keep_running = 1;

    # per-object post-loop-callbacks
    for my $plc (values %PLCMap) {
        $keep_running &&= $plc->(\%DescriptorMap, \%OtherFds);
    }

    # now we're at the very end, call callback if defined
    if (defined $PostLoopCallback) {
        $keep_running &&= $PostLoopCallback->(\%DescriptorMap, \%OtherFds);
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

    $self->{sock}        = $sock;
    my $fd = fileno($sock);

    Carp::cluck("undef sock and/or fd in PublicInbox::DS->new.  sock=" . ($sock || "") . ", fd=" . ($fd || ""))
        unless $sock && $fd;

    $self->{fd}          = $fd;
    $self->{write_buf}      = [];
    $self->{write_buf_offset} = 0;
    $self->{write_buf_size} = 0;
    $self->{closed} = 0;

    my $ev = $self->{event_watch} = POLLERR|POLLHUP|POLLNVAL;

    _InitPoller();

    if ($HaveEpoll) {
        if ($exclusive) {
            $ev = $self->{event_watch} = EPOLLIN|EPOLLERR|EPOLLHUP|$EPOLLEXCLUSIVE;
        }
retry:
        if (epoll_ctl($Epoll, EPOLL_CTL_ADD, $fd, $ev)) {
            if ($!{EINVAL} && ($ev & $EPOLLEXCLUSIVE)) {
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

=head2 C<< $obj->steal_socket() >>

Basically returns our socket and makes it so that we don't try to close it,
but we do remove it from epoll handlers.  THIS CLOSES $self.  It is the same
thing as calling close, except it gives you the socket to use.

=cut
sub steal_socket {
    my PublicInbox::DS $self = $_[0];
    return if $self->{closed};

    # cleanup does most of the work of closing this socket
    $self->_cleanup();

    # now undef our internal sock and fd structures so we don't use them
    my $sock = $self->{sock};
    $self->{sock} = undef;
    return $sock;
}

=head2 C<< $obj->close( [$reason] ) >>

Close the socket. The I<reason> argument will be used in debugging messages.

=cut
sub close {
    my PublicInbox::DS $self = $_[0];
    return if $self->{closed};

    # print out debugging info for this close
    if (DebugLevel) {
        my ($pkg, $filename, $line) = caller;
        my $reason = $_[1] || "";
        warn "Closing \#$self->{fd} due to $pkg/$filename/$line ($reason)\n";
    }

    # this does most of the work of closing us
    $self->_cleanup();

    # defer closing the actual socket until the event loop is done
    # processing this round of events.  (otherwise we might reuse fds)
    if ($self->{sock}) {
        push @ToClose, $self->{sock};
        $self->{sock} = undef;
    }

    return 0;
}

### METHOD: _cleanup()
### Called by our closers so we can clean internal data structures.
sub _cleanup {
    my PublicInbox::DS $self = $_[0];

    # we're effectively closed; we have no fd and sock when we leave here
    $self->{closed} = 1;

    # we need to flush our write buffer, as there may
    # be self-referential closures (sub { $client->close })
    # preventing the object from being destroyed
    $self->{write_buf} = [];

    # if we're using epoll, we have to remove this from our epoll fd so we stop getting
    # notifications about it
    if ($HaveEpoll && $self->{fd}) {
        if (epoll_ctl($Epoll, EPOLL_CTL_DEL, $self->{fd}, $self->{event_watch}) != 0) {
            # dump_error prints a backtrace so we can try to figure out why this happened
            $self->dump_error("epoll_ctl(): failure deleting fd=$self->{fd} during _cleanup(); $! (" . ($!+0) . ")");
        }
    }

    # now delete from mappings.  this fd no longer belongs to us, so we don't want
    # to get alerts for it if it becomes writable/readable/etc.
    delete $PLCMap{$self->{fd}};

    # we explicitly don't delete from DescriptorMap here until we
    # actually close the socket, as we might be in the middle of
    # processing an epoll_wait/etc that returned hundreds of fds, one
    # of which is not yet processed and is what we're closing.  if we
    # keep it in DescriptorMap, then the event harnesses can just
    # looked at $pob->{closed} and ignore it.  but if it's an
    # un-accounted for fd, then it (understandably) freak out a bit
    # and emit warnings, thinking their state got off.

    # and finally get rid of our fd so we can't use it anywhere else
    $self->{fd} = undef;
}

=head2 C<< $obj->sock() >>

Returns the underlying IO::Handle for the object.

=cut
sub sock {
    my PublicInbox::DS $self = shift;
    return $self->{sock};
}

=head2 C<< $obj->set_writer_func( CODEREF ) >>

Sets a function to use instead of C<syswrite()> when writing data to the socket.

=cut
sub set_writer_func {
   my PublicInbox::DS $self = shift;
   my $wtr = shift;
   Carp::croak("Not a subref") unless !defined $wtr || UNIVERSAL::isa($wtr, "CODE");
   $self->{writer_func} = $wtr;
}

=head2 C<< $obj->write( $data ) >>

Write the specified data to the underlying handle.  I<data> may be scalar,
scalar ref, code ref (to run when there), or undef just to kick-start.
Returns 1 if writes all went through, or 0 if there are writes in queue. If
it returns 1, caller should stop waiting for 'writable' events)

=cut
sub write {
    my PublicInbox::DS $self;
    my $data;
    ($self, $data) = @_;

    # nobody should be writing to closed sockets, but caller code can
    # do two writes within an event, have the first fail and
    # disconnect the other side (whose destructor then closes the
    # calling object, but it's still in a method), and then the
    # now-dead object does its second write.  that is this case.  we
    # just lie and say it worked.  it'll be dead soon and won't be
    # hurt by this lie.
    return 1 if $self->{closed};

    my $bref;

    # just queue data if there's already a wait
    my $need_queue;

    if (defined $data) {
        $bref = ref $data ? $data : \$data;
        if ($self->{write_buf_size}) {
            push @{$self->{write_buf}}, $bref;
            $self->{write_buf_size} += ref $bref eq "SCALAR" ? length($$bref) : 1;
            return 0;
        }

        # this flag says we're bypassing the queue system, knowing we're the
        # only outstanding write, and hoping we don't ever need to use it.
        # if so later, though, we'll need to queue
        $need_queue = 1;
    }

  WRITE:
    while (1) {
        return 1 unless $bref ||= $self->{write_buf}[0];

        my $len;
        eval {
            $len = length($$bref); # this will die if $bref is a code ref, caught below
        };
        if ($@) {
            if (UNIVERSAL::isa($bref, "CODE")) {
                unless ($need_queue) {
                    $self->{write_buf_size}--; # code refs are worth 1
                    shift @{$self->{write_buf}};
                }
                $bref->();

                # code refs are just run and never get reenqueued
                # (they're one-shot), so turn off the flag indicating the
                # outstanding data needs queueing.
                $need_queue = 0;

                undef $bref;
                next WRITE;
            }
            die "Write error: $@ <$bref>";
        }

        my $to_write = $len - $self->{write_buf_offset};
        my $written;
        if (my $wtr = $self->{writer_func}) {
            $written = $wtr->($bref, $to_write, $self->{write_buf_offset});
        } else {
            $written = syswrite($self->{sock}, $$bref, $to_write, $self->{write_buf_offset});
        }

        if (! defined $written) {
            if ($! == EPIPE) {
                return $self->close("EPIPE");
            } elsif ($! == EAGAIN) {
                # since connection has stuff to write, it should now be
                # interested in pending writes:
                if ($need_queue) {
                    push @{$self->{write_buf}}, $bref;
                    $self->{write_buf_size} += $len;
                }
                $self->{write_set_watch} = 1 unless $self->{event_watch} & POLLOUT;
                $self->watch_write(1);
                return 0;
            } elsif ($! == ECONNRESET) {
                return $self->close("ECONNRESET");
            }

            DebugLevel >= 1 && $self->debugmsg("Closing connection ($self) due to write error: $!\n");

            return $self->close("write_error");
        } elsif ($written != $to_write) {
            DebugLevel >= 2 && $self->debugmsg("Wrote PARTIAL %d bytes to %d",
                                               $written, $self->{fd});
            if ($need_queue) {
                push @{$self->{write_buf}}, $bref;
                $self->{write_buf_size} += $len;
            }
            # since connection has stuff to write, it should now be
            # interested in pending writes:
            $self->{write_buf_offset} += $written;
            $self->{write_buf_size} -= $written;
            $self->on_incomplete_write;
            return 0;
        } elsif ($written == $to_write) {
            DebugLevel >= 2 && $self->debugmsg("Wrote ALL %d bytes to %d (nq=%d)",
                                               $written, $self->{fd}, $need_queue);
            $self->{write_buf_offset} = 0;

            if ($self->{write_set_watch}) {
                $self->watch_write(0);
                $self->{write_set_watch} = 0;
            }

            # this was our only write, so we can return immediately
            # since we avoided incrementing the buffer size or
            # putting it in the buffer.  we also know there
            # can't be anything else to write.
            return 1 if $need_queue;

            $self->{write_buf_size} -= $written;
            shift @{$self->{write_buf}};
            undef $bref;
            next WRITE;
        }
    }
}

sub on_incomplete_write {
    my PublicInbox::DS $self = shift;
    $self->{write_set_watch} = 1 unless $self->{event_watch} & POLLOUT;
    $self->watch_write(1);
}

=head2 C<< $obj->read( $bytecount ) >>

Read at most I<bytecount> bytes from the underlying handle; returns scalar
ref on read, or undef on connection closed.

=cut
sub read {
    my PublicInbox::DS $self = shift;
    return if $self->{closed};
    my $bytes = shift;
    my $buf;
    my $sock = $self->{sock};

    # if this is too high, perl quits(!!).  reports on mailing lists
    # don't seem to point to a universal answer.  5MB worked for some,
    # crashed for others.  1MB works for more people.  let's go with 1MB
    # for now.  :/
    my $req_bytes = $bytes > 1048576 ? 1048576 : $bytes;

    my $res = sysread($sock, $buf, $req_bytes, 0);
    DebugLevel >= 2 && $self->debugmsg("sysread = %d; \$! = %d", $res, $!);

    if (! $res && $! != EWOULDBLOCK) {
        # catches 0=conn closed or undef=error
        DebugLevel >= 2 && $self->debugmsg("Fd \#%d read hit the end of the road.", $self->{fd});
        return undef;
    }

    return \$buf;
}

=head2 (VIRTUAL) C<< $obj->event_read() >>

Readable event handler. Concrete deriviatives of PublicInbox::DS should
provide an implementation of this. The default implementation will die if
called.

=cut
sub event_read  { die "Base class event_read called for $_[0]\n"; }

=head2 (VIRTUAL) C<< $obj->event_err() >>

Error event handler. Concrete deriviatives of PublicInbox::DS should
provide an implementation of this. The default implementation will die if
called.

=cut
sub event_err   { die "Base class event_err called for $_[0]\n"; }

=head2 (VIRTUAL) C<< $obj->event_hup() >>

'Hangup' event handler. Concrete deriviatives of PublicInbox::DS should
provide an implementation of this. The default implementation will die if
called.

=cut
sub event_hup   { die "Base class event_hup called for $_[0]\n"; }

=head2 C<< $obj->event_write() >>

Writable event handler. Concrete deriviatives of PublicInbox::DS may wish to
provide an implementation of this. The default implementation calls
C<write()> with an C<undef>.

=cut
sub event_write {
    my $self = shift;
    $self->write(undef);
}

=head2 C<< $obj->watch_read( $boolean ) >>

Turn 'readable' event notification on or off.

=cut
sub watch_read {
    my PublicInbox::DS $self = shift;
    return if $self->{closed} || !$self->{sock};

    my $val = shift;
    my $event = $self->{event_watch};

    $event &= ~POLLIN if ! $val;
    $event |=  POLLIN if   $val;

    # If it changed, set it
    if ($event != $self->{event_watch}) {
        if ($HaveKQueue) {
            $KQueue->EV_SET($self->{fd}, IO::KQueue::EVFILT_READ(),
                            $val ? IO::KQueue::EV_ENABLE() : IO::KQueue::EV_DISABLE());
        }
        elsif ($HaveEpoll) {
            epoll_ctl($Epoll, EPOLL_CTL_MOD, $self->{fd}, $event)
                and $self->dump_error("couldn't modify epoll settings for $self->{fd} " .
                                      "from $self->{event_watch} -> $event: $! (" . ($!+0) . ")");
        }
        $self->{event_watch} = $event;
    }
}

=head2 C<< $obj->watch_write( $boolean ) >>

Turn 'writable' event notification on or off.

=cut
sub watch_write {
    my PublicInbox::DS $self = shift;
    return if $self->{closed} || !$self->{sock};

    my $val = shift;
    my $event = $self->{event_watch};

    $event &= ~POLLOUT if ! $val;
    $event |=  POLLOUT if   $val;

    if ($val && caller ne __PACKAGE__) {
        # A subclass registered interest, it's now responsible for this.
        $self->{write_set_watch} = 0;
    }

    # If it changed, set it
    if ($event != $self->{event_watch}) {
        if ($HaveKQueue) {
            $KQueue->EV_SET($self->{fd}, IO::KQueue::EVFILT_WRITE(),
                            $val ? IO::KQueue::EV_ENABLE() : IO::KQueue::EV_DISABLE());
        }
        elsif ($HaveEpoll) {
            epoll_ctl($Epoll, EPOLL_CTL_MOD, $self->{fd}, $event)
                and $self->dump_error("couldn't modify epoll settings for $self->{fd} " .
                                      "from $self->{event_watch} -> $event: $! (" . ($!+0) . ")");
        }
        $self->{event_watch} = $event;
    }
}

=head2 C<< $obj->dump_error( $message ) >>

Prints to STDERR a backtrace with information about this socket and what lead
up to the dump_error call.

=cut
sub dump_error {
    my $i = 0;
    my @list;
    while (my ($file, $line, $sub) = (caller($i++))[1..3]) {
        push @list, "\t$file:$line called $sub\n";
    }

    warn "ERROR: $_[1]\n" .
        "\t$_[0] = " . $_[0]->as_string . "\n" .
        join('', @list);
}

=head2 C<< $obj->debugmsg( $format, @args ) >>

Print the debugging message specified by the C<sprintf>-style I<format> and
I<args>.

=cut
sub debugmsg {
    my ( $self, $fmt, @args ) = @_;
    confess "Not an object" unless ref $self;

    chomp $fmt;
    printf STDERR ">>> $fmt\n", @args;
}

=head2 C<< $obj->as_string() >>

Returns a string describing this socket.

=cut
sub as_string {
    my PublicInbox::DS $self = shift;
    my $rw = "(" . ($self->{event_watch} & POLLIN ? 'R' : '') .
                   ($self->{event_watch} & POLLOUT ? 'W' : '') . ")";
    my $ret = ref($self) . "$rw: " . ($self->{closed} ? "closed" : "open");
    return $ret;
}

sub _undef {
    return undef unless $ENV{DS_DEBUG};
    my $msg = shift || "";
    warn "PublicInbox::DS: $msg\n";
    return undef;
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
