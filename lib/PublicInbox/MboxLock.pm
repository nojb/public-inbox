# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Various mbox locking methods
package PublicInbox::MboxLock;
use strict;
use v5.10.1;
use PublicInbox::OnDestroy;
use Fcntl qw(:flock F_SETLK F_SETLKW F_RDLCK F_WRLCK
			O_CREAT O_EXCL O_WRONLY SEEK_SET);
use Carp qw(croak);
use PublicInbox::DS qw(now); # ugh...

our $TMPL = do {
	if ($^O eq 'linux') { \'s @32' }
	elsif ($^O =~ /bsd/) { \'@20 s @256' } # n.b. @32 may be enough...
	else { eval { require File::FcntlLock; 1 } }
};

# This order matches Debian policy on Linux systems.
# See policy/ch-customized-programs.rst in
# https://salsa.debian.org/dbnpolicy/policy.git
sub defaults { [ qw(fcntl dotlock) ] }

sub acq_fcntl {
	my ($self) = @_;
	my $op = $self->{nb} ? F_SETLK : F_SETLKW;
	my $t = $self->{rw} ? F_WRLCK : F_RDLCK;
	my $end = now + $self->{timeout};
	$TMPL or die <<EOF;
"struct flock" layout not available on $^O, install File::FcntlLock?
EOF
	do {
		if (ref $TMPL) {
			return if fcntl($self->{fh}, $op, pack($$TMPL, $t));
		} else {
			my $fl = File::FcntlLock->new;
			$fl->l_type($t);
			$fl->l_whence(SEEK_SET);
			$fl->l_start(0);
			$fl->l_len(0);
			return if $fl->lock($self->{fh}, $op);
		}
		select(undef, undef, undef, $self->{delay});
	} while (now < $end);
	die "fcntl lock timeout $self->{f}: $!\n";
}

sub acq_dotlock {
	my ($self) = @_;
	my $dot_lock = "$self->{f}.lock";
	my ($pfx, $base) = ($self->{f} =~ m!(\A.*?/)?([^/]+)\z!);
	$pfx //= '';
	my $pid = $$;
	my $end = now + $self->{timeout};
	do {
		my $tmp = "$pfx.$base-".sprintf('%x,%x,%x',
					rand(0xffffffff), $pid, time);
		if (sysopen(my $fh, $tmp, O_CREAT|O_EXCL|O_WRONLY)) {
			if (link($tmp, $dot_lock)) {
				unlink($tmp) or die "unlink($tmp): $!";
				$self->{".lock$pid"} = $dot_lock;
				return;
			}
			unlink($tmp) or die "unlink($tmp): $!";
			select(undef, undef, undef, $self->{delay});
		} else {
			croak "open $tmp (for $dot_lock): $!" if !$!{EXIST};
		}
	} while (now < $end);
	die "dotlock timeout $dot_lock\n";
}

sub acq_flock {
	my ($self) = @_;
	my $op = $self->{rw} ? LOCK_EX : LOCK_SH;
	$op |= LOCK_NB if $self->{nb};
	my $end = now + $self->{timeout};
	do {
		return if flock($self->{fh}, $op);
		select(undef, undef, undef, $self->{delay});
	} while (now < $end);
	die "flock timeout $self->{f}: $!\n";
}

sub acq {
	my ($cls, $f, $rw, $methods) = @_;
	my $fh;
	unless (open $fh, $rw ? '+>>' : '<', $f) {
		croak "open($f): $!" if $rw || !$!{ENOENT};
	}
	my $self = bless { f => $f, fh => $fh, rw => $rw }, $cls;
	my $m = "@$methods";
	if ($m ne 'none') {
		my @m = map {
			if (/\A(timeout|delay)=([0-9\.]+)s?\z/) {
				$self->{$1} = $2 + 0;
				();
			} else {
				$cls->can("acq_$_") // $_
			}
		} split(/[, ]/, $m);
		my @bad = grep { !ref } @m;
		croak "Unsupported lock methods: @bad\n" if @bad;
		croak "No lock methods supplied with $m\n" if !@m;
		$self->{nb} = $#m || defined($self->{timeout});
		$self->{delay} //= 0.1;
		$self->{timeout} //= 5;
		$_->($self) for @m;
	}
	$self;
}

sub DESTROY {
	my ($self) = @_;
	if (my $f = $self->{".lock$$"}) {
		unlink($f) or die "unlink($f): $! (lock stolen?)";
	}
}

1;
