# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# base class for remote IPC calls, requires Storable
# TODO: this ought to be usable in SearchIdxShard
package PublicInbox::IPC;
use strict;
use v5.10.1;
use Socket qw(AF_UNIX SOCK_STREAM);
use Carp qw(confess croak);
use PublicInbox::Sigfd;

sub _get_rec ($) {
	my ($sock) = @_;
	local $/ = "\n";
	defined(my $len = <$sock>) or return;
	chop($len) eq "\n" or croak "no LF byte in $len";
	defined(my $r = read($sock, my $buf, $len)) or croak "read error: $!";
	$r == $len or croak "short read: $r != $len";
	thaw($buf);
}

sub _send_rec ($$) {
	my ($sock, $ref) = @_;
	my $buf = freeze($ref);
	print $sock length($buf), "\n", $buf or croak "print: $!";
}

sub ipc_return ($$$) {
	my ($s2, $ret, $exc) = @_;
	_send_rec($s2, $exc ? bless(\$exc, 'PublicInbox::IPC::Die') : $ret);
}

sub ipc_worker_loop ($$) {
	my ($self, $s2) = @_;
	$self->ipc_atfork_child if $self->can('ipc_atfork_child');
	$s2->autoflush(1);
	while (my $rec = _get_rec($s2)) {
		my ($wantarray, $sub, @args) = @$rec;
		if (!defined($wantarray)) { # no waiting if client doesn't care
			eval { $self->$sub(@args) };
			eval { warn "die: $@ (from nowait $sub)\n" } if $@;
		} elsif ($wantarray) {
			my @ret = eval { $self->$sub(@args) };
			ipc_return($s2, \@ret, $@);
		} else {
			my $ret = eval { $self->$sub(@args) };
			ipc_return($s2, \$ret, $@);
		}
	}
}

sub ipc_worker_spawn ($$$) {
	my ($self, $ident, $oldset) = @_;
	eval { require Storable; Storable->import(qw(freeze thaw)); };
	if ($@) {
		state $w //= warn "Storable (part of Perl) missing: $@\n";
		return;
	}
	my $pid = $self->{-ipc_worker_pid};
	confess "BUG: already spawned PID:$pid" if $pid;
	confess "BUG: already have worker socket" if $self->{-ipc_sock};
	my ($s1, $s2);
	socketpair($s1, $s2, AF_UNIX, SOCK_STREAM, 0) or die "socketpair: $!";
	my $sigset = $oldset // PublicInbox::Sigfd::block_signals();
	defined($pid = fork) or die "fork: $!";
	if ($pid == 0) {
		undef $s1;
		local $0 = $ident;
		$SIG{$_} = 'IGNORE' for (qw(TERM INT QUIT));
		PublicInbox::Sigfd::sig_setmask($oldset);
		eval { ipc_worker_loop($self, $s2) };
		die "worker $ident died: $@\n" if $@;
		$self->ipc_at_worker_exit if $self->can('ipc_at_worker_exit');
		exit;
	}
	PublicInbox::Sigfd::sig_setmask($sigset) unless $oldset;
	$s1->autoflush(1);
	$self->{-ipc_sock} = $s1;
	$self->{-ipc_worker_pid} = $pid;
}

sub ipc_reap_worker { # dwaitpid callback
	my ($self, $pid) = @_;
	warn "PID:$pid died with \$?=$?\n" if $?;
}

sub ipc_worker_stop {
	my ($self) = @_;
	my $pid;
	if (delete $self->{-ipc_sock}) {
		$pid = delete $self->{-ipc_worker_pid} or die "no PID?";
	} else {
		$pid = delete $self->{-ipc_worker_pid} and
			die "unexpected PID:$pid";
	}
	return unless $pid;
	eval { PublicInbox::DS::dwaitpid($pid, \&ipc_reap_worker, $self) };
	if ($@) {
		my $wp = waitpid($pid, 0);
		$pid == $wp or die "waitpid($pid) returned $wp: \$?=$?";
		ipc_reap_worker($self, $pid);
	}
}

# use this if we have multiple readers reading curl or "pigz -dc"
# and writing to the same store
sub ipc_lock_init {
	my ($self, $f) = @_;
	require PublicInbox::Lock;
	$self->{-ipc_lock} //= bless { lock_path => $f }, 'PublicInbox::Lock'
}

sub ipc_do {
	my ($self, $sub, @args) = @_;
	if (my $s1 = $self->{-ipc_sock}) {
		my $ipc_lock = $self->{-ipc_lock};
		my $lock = $ipc_lock ? $ipc_lock->lock_for_scope : undef;
		_send_rec($s1, [ wantarray, $sub, @args ]);
		return unless defined(wantarray);
		my $ret = _get_rec($s1) // die "no response on $sub";
		die $$ret if ref($ret) eq 'PublicInbox::IPC::Die';
		wantarray ? @$ret : $$ret;
	} else {
		$self->$sub(@args);
	}
}

1;
