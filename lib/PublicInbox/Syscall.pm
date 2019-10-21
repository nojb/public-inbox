# This is a fork of the (for now) unmaintained Sys::Syscall 0.25,
# specifically the Debian libsys-syscall-perl 0.25-6 version to
# fix upstream regressions in 0.25.
#
# This license differs from the rest of public-inbox
#
# This module is Copyright (c) 2005 Six Apart, Ltd.
# Copyright (C) 2019 all contributors <meta@public-inbox.org>
#
# All rights reserved.
#
# You may distribute under the terms of either the GNU General Public
# License or the Artistic License, as specified in the Perl README file.
package PublicInbox::Syscall;
use strict;
use POSIX qw(ENOSYS SEEK_CUR);
use Config;

require Exporter;
use vars qw(@ISA @EXPORT_OK %EXPORT_TAGS $VERSION);

$VERSION     = "0.25";
@ISA         = qw(Exporter);
@EXPORT_OK   = qw(epoll_ctl epoll_create epoll_wait
                  EPOLLIN EPOLLOUT EPOLLET
                  EPOLL_CTL_ADD EPOLL_CTL_DEL EPOLL_CTL_MOD
                  EPOLLONESHOT EPOLLEXCLUSIVE);
%EXPORT_TAGS = (epoll => [qw(epoll_ctl epoll_create epoll_wait
                             EPOLLIN EPOLLOUT
                             EPOLL_CTL_ADD EPOLL_CTL_DEL EPOLL_CTL_MOD
                             EPOLLONESHOT EPOLLEXCLUSIVE)],
                );

use constant EPOLLIN       => 1;
use constant EPOLLOUT      => 4;
# use constant EPOLLERR      => 8;
# use constant EPOLLHUP      => 16;
# use constant EPOLLRDBAND   => 128;
use constant EPOLLEXCLUSIVE => (1 << 28);
use constant EPOLLONESHOT => (1 << 30);
use constant EPOLLET => (1 << 31);
use constant EPOLL_CTL_ADD => 1;
use constant EPOLL_CTL_DEL => 2;
use constant EPOLL_CTL_MOD => 3;

our $loaded_syscall = 0;

sub _load_syscall {
    # props to Gaal for this!
    return if $loaded_syscall++;
    my $clean = sub {
        delete @INC{qw<syscall.ph asm/unistd.ph bits/syscall.ph
                        _h2ph_pre.ph sys/syscall.ph>};
    };
    $clean->(); # don't trust modules before us
    my $rv = eval { require 'syscall.ph'; 1 } || eval { require 'sys/syscall.ph'; 1 };
    $clean->(); # don't require modules after us trust us
    return $rv;
}


our (
     $SYS_epoll_create,
     $SYS_epoll_ctl,
     $SYS_epoll_wait,
     );

our $no_deprecated = 0;

if ($^O eq "linux") {
    my $machine = (POSIX::uname())[-1];
    # whether the machine requires 64-bit numbers to be on 8-byte
    # boundaries.
    my $u64_mod_8 = 0;

    # if we're running on an x86_64 kernel, but a 32-bit process,
    # we need to use the i386 syscall numbers.
    if ($machine eq "x86_64" && $Config{ptrsize} == 4) {
        $machine = "i386";
    }

    # Similarly for mips64 vs mips
    if ($machine eq "mips64" && $Config{ptrsize} == 4) {
        $machine = "mips";
    }

    if ($machine =~ m/^i[3456]86$/) {
        $SYS_epoll_create = 254;
        $SYS_epoll_ctl    = 255;
        $SYS_epoll_wait   = 256;
    } elsif ($machine eq "x86_64") {
        $SYS_epoll_create = 213;
        $SYS_epoll_ctl    = 233;
        $SYS_epoll_wait   = 232;
    } elsif ($machine =~ m/^parisc/) {
        $SYS_epoll_create = 224;
        $SYS_epoll_ctl    = 225;
        $SYS_epoll_wait   = 226;
        $u64_mod_8        = 1;
    } elsif ($machine =~ m/^ppc64/) {
        $SYS_epoll_create = 236;
        $SYS_epoll_ctl    = 237;
        $SYS_epoll_wait   = 238;
        $u64_mod_8        = 1;
    } elsif ($machine eq "ppc") {
        $SYS_epoll_create = 236;
        $SYS_epoll_ctl    = 237;
        $SYS_epoll_wait   = 238;
        $u64_mod_8        = 1;
    } elsif ($machine =~ m/^s390/) {
        $SYS_epoll_create = 249;
        $SYS_epoll_ctl    = 250;
        $SYS_epoll_wait   = 251;
        $u64_mod_8        = 1;
    } elsif ($machine eq "ia64") {
        $SYS_epoll_create = 1243;
        $SYS_epoll_ctl    = 1244;
        $SYS_epoll_wait   = 1245;
        $u64_mod_8        = 1;
    } elsif ($machine eq "alpha") {
        # natural alignment, ints are 32-bits
        $SYS_epoll_create = 407;
        $SYS_epoll_ctl    = 408;
        $SYS_epoll_wait   = 409;
        $u64_mod_8        = 1;
    } elsif ($machine eq "aarch64") {
        $SYS_epoll_create = 20;  # (sys_epoll_create1)
        $SYS_epoll_ctl    = 21;
        $SYS_epoll_wait   = 22;  # (sys_epoll_pwait)
        $u64_mod_8        = 1;
        $no_deprecated    = 1;
    } elsif ($machine =~ m/arm(v\d+)?.*l/) {
        # ARM OABI
        $SYS_epoll_create = 250;
        $SYS_epoll_ctl    = 251;
        $SYS_epoll_wait   = 252;
        $u64_mod_8        = 1;
    } elsif ($machine =~ m/^mips64/) {
        $SYS_epoll_create = 5207;
        $SYS_epoll_ctl    = 5208;
        $SYS_epoll_wait   = 5209;
        $u64_mod_8        = 1;
    } elsif ($machine =~ m/^mips/) {
        $SYS_epoll_create = 4248;
        $SYS_epoll_ctl    = 4249;
        $SYS_epoll_wait   = 4250;
        $u64_mod_8        = 1;
    } else {
        # as a last resort, try using the *.ph files which may not
        # exist or may be wrong
        _load_syscall();
        $SYS_epoll_create = eval { &SYS_epoll_create; } || 0;
        $SYS_epoll_ctl    = eval { &SYS_epoll_ctl;    } || 0;
        $SYS_epoll_wait   = eval { &SYS_epoll_wait;   } || 0;
    }

    if ($u64_mod_8) {
        *epoll_wait = \&epoll_wait_mod8;
        *epoll_ctl = \&epoll_ctl_mod8;
    } else {
        *epoll_wait = \&epoll_wait_mod4;
        *epoll_ctl = \&epoll_ctl_mod4;
    }
}

elsif ($^O eq "freebsd") {
    if ($ENV{FREEBSD_SENDFILE}) {
        # this is still buggy and in development
    }
}

############################################################################
# epoll functions
############################################################################

sub epoll_defined { return $SYS_epoll_create ? 1 : 0; }

sub epoll_create {
	syscall($SYS_epoll_create, $no_deprecated ? 0 : ($_[0]||100)+0);
}

# epoll_ctl wrapper
# ARGS: (epfd, op, fd, events_mask)
sub epoll_ctl_mod4 {
    syscall($SYS_epoll_ctl, $_[0]+0, $_[1]+0, $_[2]+0, pack("LLL", $_[3], $_[2], 0));
}
sub epoll_ctl_mod8 {
    syscall($SYS_epoll_ctl, $_[0]+0, $_[1]+0, $_[2]+0, pack("LLLL", $_[3], 0, $_[2], 0));
}

# epoll_wait wrapper
# ARGS: (epfd, maxevents, timeout (milliseconds), arrayref)
#  arrayref: values modified to be [$fd, $event]
our $epoll_wait_events;
our $epoll_wait_size = 0;
sub epoll_wait_mod4 {
    # resize our static buffer if requested size is bigger than we've ever done
    if ($_[1] > $epoll_wait_size) {
        $epoll_wait_size = $_[1];
        $epoll_wait_events = "\0" x 12 x $epoll_wait_size;
    }
    my $ct = syscall($SYS_epoll_wait, $_[0]+0, $epoll_wait_events, $_[1]+0, $_[2]+0);
    for (0..$ct-1) {
        @{$_[3]->[$_]}[1,0] = unpack("LL", substr($epoll_wait_events, 12*$_, 8));
    }
    return $ct;
}

sub epoll_wait_mod8 {
    # resize our static buffer if requested size is bigger than we've ever done
    if ($_[1] > $epoll_wait_size) {
        $epoll_wait_size = $_[1];
        $epoll_wait_events = "\0" x 16 x $epoll_wait_size;
    }
    my $ct;
    if ($no_deprecated) {
        $ct = syscall($SYS_epoll_wait, $_[0]+0, $epoll_wait_events, $_[1]+0, $_[2]+0, undef);
    } else {
        $ct = syscall($SYS_epoll_wait, $_[0]+0, $epoll_wait_events, $_[1]+0, $_[2]+0);
    }
    for (0..$ct-1) {
        # 16 byte epoll_event structs, with format:
        #    4 byte mask [idx 1]
        #    4 byte padding (we put it into idx 2, useless)
        #    8 byte data (first 4 bytes are fd, into idx 0)
        @{$_[3]->[$_]}[1,2,0] = unpack("LLL", substr($epoll_wait_events, 16*$_, 12));
    }
    return $ct;
}

1;

=head1 WARRANTY

This is free software. IT COMES WITHOUT WARRANTY OF ANY KIND.

=head1 AUTHORS

Brad Fitzpatrick <brad@danga.com>
