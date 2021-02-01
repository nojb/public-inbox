# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# base class for remote IPC calls and workqueues, requires Storable or Sereal
# - ipc_do and ipc_worker_* is for a single worker/producer and uses pipes
# - wq_do and wq_worker* is for a single producer and multiple workers,
#   using SOCK_SEQPACKET for work distribution
# use ipc_do when you need work done on a certain process
# use wq_do when your work can be done on any idle worker
package PublicInbox::IPC;
use strict;
use v5.10.1;
use Carp qw(confess croak);
use PublicInbox::DS qw(dwaitpid);
use PublicInbox::Spawn;
use PublicInbox::OnDestroy;
use PublicInbox::WQWorker;
use Socket qw(AF_UNIX MSG_EOR SOCK_STREAM);
my $SEQPACKET = eval { Socket::SOCK_SEQPACKET() }; # portable enough?
use constant PIPE_BUF => $^O eq 'linux' ? 4096 : POSIX::_POSIX_PIPE_BUF();
my $WQ_MAX_WORKERS = 4096;
my ($enc, $dec);
# ->imports at BEGIN turns sereal_*_with_object into custom ops on 5.14+
# and eliminate method call overhead
BEGIN {
	eval {
		require Sereal::Encoder;
		require Sereal::Decoder;
		Sereal::Encoder->import('sereal_encode_with_object');
		Sereal::Decoder->import('sereal_decode_with_object');
		($enc, $dec) = (Sereal::Encoder->new, Sereal::Decoder->new);
	};
};

if ($enc && $dec) { # should be custom ops
	*freeze = sub ($) { sereal_encode_with_object $enc, $_[0] };
	*thaw = sub ($) { sereal_decode_with_object $dec, $_[0], my $ret };
} else {
	eval { # some distros have Storable as a separate package from Perl
		require Storable;
		Storable->import(qw(freeze thaw));
		$enc = 1;
	} // warn("Storable (part of Perl) missing: $@\n");
}

my $recv_cmd = PublicInbox::Spawn->can('recv_cmd4');
my $send_cmd = PublicInbox::Spawn->can('send_cmd4') // do {
	require PublicInbox::CmdIPC4;
	$recv_cmd //= PublicInbox::CmdIPC4->can('recv_cmd4');
	PublicInbox::CmdIPC4->can('send_cmd4');
};

sub _get_rec ($) {
	my ($r) = @_;
	defined(my $len = <$r>) or return;
	chop($len) eq "\n" or croak "no LF byte in $len";
	defined(my $n = read($r, my $buf, $len)) or croak "read error: $!";
	$n == $len or croak "short read: $n != $len";
	thaw($buf);
}

sub _pack_rec ($) {
	my ($ref) = @_;
	my $buf = freeze($ref);
	length($buf) . "\n" . $buf;
}

sub _send_rec ($$) {
	my ($w, $ref) = @_;
	print $w _pack_rec($ref) or croak "print: $!";
}

sub ipc_return ($$$) {
	my ($w, $ret, $exc) = @_;
	_send_rec($w, $exc ? bless(\$exc, 'PublicInbox::IPC::Die') : $ret);
}

sub ipc_worker_loop ($$$) {
	my ($self, $r_req, $w_res) = @_;
	my ($rec, $wantarray, $sub, @args);
	local $/ = "\n";
	while ($rec = _get_rec($r_req)) {
		($wantarray, $sub, @args) = @$rec;
		# no waiting if client doesn't care,
		# this is the overwhelmingly likely case
		if (!defined($wantarray)) {
			eval { $self->$sub(@args) };
			warn "$$ die: $@ (from nowait $sub)\n" if $@;
		} elsif ($wantarray) {
			my @ret = eval { $self->$sub(@args) };
			ipc_return($w_res, \@ret, $@);
		} else { # '' => wantscalar
			my $ret = eval { $self->$sub(@args) };
			ipc_return($w_res, \$ret, $@);
		}
	}
}

# starts a worker if Sereal or Storable is installed
sub ipc_worker_spawn {
	my ($self, $ident, $oldset) = @_;
	return unless $enc; # no Sereal or Storable
	return if ($self->{-ipc_ppid} // -1) == $$; # idempotent
	delete(@$self{qw(-ipc_req -ipc_res -ipc_ppid -ipc_pid)});
	pipe(my ($r_req, $w_req)) or die "pipe: $!";
	pipe(my ($r_res, $w_res)) or die "pipe: $!";
	my $sigset = $oldset // PublicInbox::DS::block_signals();
	$self->ipc_atfork_prepare;
	my $seed = rand(0xffffffff);
	my $pid = fork // die "fork: $!";
	if ($pid == 0) {
		srand($seed);
		eval { PublicInbox::DS->Reset };
		delete @$self{qw(-wq_s1 -wq_s2 -wq_workers -wq_ppid)};
		$w_req = $r_res = undef;
		$w_res->autoflush(1);
		$SIG{$_} = 'IGNORE' for (qw(TERM INT QUIT));
		local $0 = $ident;
		PublicInbox::DS::sig_setmask($sigset);
		# ensure we properly exit even if warn() dies:
		my $end = PublicInbox::OnDestroy->new($$, sub { exit(!!$@) });
		eval {
			my $on_destroy = $self->ipc_atfork_child;
			local %SIG = %SIG;
			ipc_worker_loop($self, $r_req, $w_res);
		};
		die "worker $ident PID:$$ died: $@\n" if $@;
		undef $end; # trigger exit
	}
	PublicInbox::DS::sig_setmask($sigset) unless $oldset;
	$r_req = $w_res = undef;
	$w_req->autoflush(1);
	$self->{-ipc_req} = $w_req;
	$self->{-ipc_res} = $r_res;
	$self->{-ipc_ppid} = $$;
	$self->{-ipc_pid} = $pid;
}

sub ipc_worker_reap { # dwaitpid callback
	my ($self, $pid) = @_;
	return if !$?;
	# TERM(15) is our default exit signal, PIPE(13) is likely w/ pager
	my $s = $? & 127;
	warn "PID:$pid died with \$?=$?\n" if $s != 15 && $s != 13;
}

sub wq_wait_old {
	my ($self) = @_;
	my $pids = delete $self->{"-wq_old_pids.$$"} or return;
	dwaitpid($_, \&ipc_worker_reap, $self) for @$pids;
}

# for base class, override in sub classes
sub ipc_atfork_prepare {}

sub wq_atexit_child {}

sub ipc_atfork_child {
	my ($self) = @_;
	my $io = delete($self->{-ipc_atfork_child_close}) or return;
	close($_) for @$io;
	undef;
}

# idempotent, can be called regardless of whether worker is active or not
sub ipc_worker_stop {
	my ($self) = @_;
	my ($pid, $ppid) = delete(@$self{qw(-ipc_pid -ipc_ppid)});
	my ($w_req, $r_res) = delete(@$self{qw(-ipc_req -ipc_res)});
	if (!$w_req && !$r_res) {
		die "unexpected PID:$pid without IPC pipes" if $pid;
		return; # idempotent
	}
	die 'no PID with IPC pipes' unless $pid;
	$w_req = $r_res = undef;

	return if $$ != $ppid;
	dwaitpid($pid, \&ipc_worker_reap, $self);
}

# use this if we have multiple readers reading curl or "pigz -dc"
# and writing to the same store
sub ipc_lock_init {
	my ($self, $f) = @_;
	require PublicInbox::Lock;
	$self->{-ipc_lock} //= bless { lock_path => $f }, 'PublicInbox::Lock'
}

sub ipc_async_wait ($$) {
	my ($self, $max) = @_; # max == -1 to wait for all
	my $aif = $self->{-async_inflight} or return;
	my $r_res = $self->{-ipc_res} or die 'BUG: no ipc_res';
	while (my ($sub, $bytes, $cb, $cb_arg) = splice(@$aif, 0, 4)) {
		my $ret = _get_rec($r_res) //
			die "no response on $sub (req.size=$bytes)";
		$self->{-async_inflight_bytes} -= $bytes;

		eval { $cb->($cb_arg, $ret) };
		warn "E: $sub callback error: $@\n" if $@;
		return if --$max == 0;
	}
}

# call $self->$sub(@args), on a worker if ipc_worker_spawn was used
sub ipc_do {
	my ($self, $sub, @args) = @_;
	if (my $w_req = $self->{-ipc_req}) { # run in worker
		my $ipc_lock = $self->{-ipc_lock};
		my $lock = $ipc_lock ? $ipc_lock->lock_for_scope : undef;
		if (defined(wantarray)) {
			my $r_res = $self->{-ipc_res} or die 'BUG: no ipc_res';
			ipc_async_wait($self, -1);
			_send_rec($w_req, [ wantarray, $sub, @args ]);
			my $ret = _get_rec($r_res) // die "no response on $sub";
			die $$ret if ref($ret) eq 'PublicInbox::IPC::Die';
			wantarray ? @$ret : $$ret;
		} else { # likely, fire-and-forget into pipe
			_send_rec($w_req, [ undef , $sub, @args ]);
		}
	} else { # run locally
		$self->$sub(@args);
	}
}

sub ipc_async {
	my ($self, $sub, $sub_args, $cb, $cb_arg) = @_;
	if (my $w_req = $self->{-ipc_req}) { # run in worker
		my $rec = _pack_rec([ 1, $sub, @$sub_args ]);
		my $cur_bytes = \($self->{-async_inflight_bytes} //= 0);
		while (($$cur_bytes + length($rec)) > PIPE_BUF) {
			ipc_async_wait($self, 1);
		}
		my $ipc_lock = $self->{-ipc_lock};
		my $lock = $ipc_lock ? $ipc_lock->lock_for_scope : undef;
		print $w_req $rec or croak "print: $!";
		$$cur_bytes += length($rec);
		push @{$self->{-async_inflight}},
				$sub, length($rec), $cb, $cb_arg;
	} else {
		my $ret = [ eval { $self->$sub(@$sub_args) } ];
		if (my $exc = $@) {
			$ret = ( bless(\$exc, 'PublicInbox::IPC::Die') );
		}
		eval { $cb->($cb_arg, $ret) };
		warn "E: $sub callback error: $@\n" if $@;
	}
}

# needed when there's multiple IPC workers and the parent forking
# causes newer siblings to inherit older siblings sockets
sub ipc_sibling_atfork_child {
	my ($self) = @_;
	my ($pid, undef) = delete(@$self{qw(-ipc_pid -ipc_ppid)});
	delete(@$self{qw(-ipc_req -ipc_res)});
	$pid == $$ and die "BUG: $$ ipc_atfork_child called on itself";
}

sub recv_and_run {
	my ($self, $s2, $len, $full_stream) = @_;
	my @fds = $recv_cmd->($s2, my $buf, $len);
	return if scalar(@fds) && !defined($fds[0]);
	my $n = length($buf) or return 0;
	my $nfd = 0;
	for my $fd (@fds) {
		if (open(my $cmdfh, '+<&=', $fd)) {
			$self->{$nfd++} = $cmdfh;
			$cmdfh->autoflush(1);
		} else {
			die "$$ open(+<&=$fd) (FD:$nfd): $!";
		}
	}
	while ($full_stream && $n < $len) {
		my $r = sysread($s2, $buf, $len - $n, $n) // croak "read: $!";
		croak "read EOF after $n/$len bytes" if $r == 0;
		$n = length($buf);
	}
	# Sereal dies on truncated data, Storable returns undef
	my $args = thaw($buf) // die "thaw error on buffer of size: $n";
	undef $buf;
	my $sub = shift @$args;
	eval { $self->$sub(@$args) };
	warn "$$ wq_worker: $@" if $@;
	delete @$self{0..($nfd-1)};
	$n;
}

sub wq_worker_loop ($) {
	my ($self) = @_;
	my $wqw = PublicInbox::WQWorker->new($self);
	PublicInbox::DS->SetPostLoopCallback(sub { $wqw->{sock} });
	PublicInbox::DS->EventLoop;
	PublicInbox::DS->Reset;
}

sub do_sock_stream { # via wq_do, for big requests
	my ($self, $len) = @_;
	recv_and_run($self, delete $self->{0}, $len, 1);
}

sub wq_do { # always async
	my ($self, $sub, $ios, @args) = @_;
	if (my $s1 = $self->{-wq_s1}) { # run in worker
		my $fds = [ map { fileno($_) } @$ios ];
		my $n = $send_cmd->($s1, $fds, freeze([$sub, @args]), MSG_EOR);
		return if defined($n); # likely
		croak "sendmsg: $! (check RLIMIT_NOFILE)" if $!{ETOOMANYREFS};
		croak "sendmsg: $!" if !$!{EMSGSIZE};
		socketpair(my $r, my $w, AF_UNIX, SOCK_STREAM, 0) or
			croak "socketpair: $!";
		my $buf = freeze([$sub, @args]);
		$n = $send_cmd->($s1, [ fileno($r) ],
				freeze(['do_sock_stream', length($buf)]),
				MSG_EOR) // croak "sendmsg: $!";
		undef $r;
		$n = $send_cmd->($w, $fds, $buf, 0) // croak "sendmsg: $!";
		while ($n < length($buf)) {
			my $x = syswrite($w, $buf, length($buf) - $n, $n) //
					croak "syswrite: $!";
			croak "syswrite wrote 0 bytes" if $x == 0;
			$n += $x;
		}
	} else {
		@$self{0..$#$ios} = @$ios;
		eval { $self->$sub(@args) };
		warn "wq_do: $@" if $@;
		delete @$self{0..$#$ios}; # don't close
	}
}

sub _wq_worker_start ($$$) {
	my ($self, $oldset, $fields) = @_;
	my $seed = rand(0xffffffff);
	my $pid = fork // die "fork: $!";
	if ($pid == 0) {
		srand($seed);
		eval { PublicInbox::DS->Reset };
		delete @$self{qw(-wq_s1 -wq_workers -wq_ppid)};
		@$self{keys %$fields} = values(%$fields) if $fields;
		$SIG{$_} = 'IGNORE' for (qw(PIPE));
		$SIG{$_} = 'DEFAULT' for (qw(TTOU TTIN TERM QUIT INT CHLD));
		local $0 = $self->{-wq_ident};
		PublicInbox::DS::sig_setmask($oldset);
		# ensure we properly exit even if warn() dies:
		my $end = PublicInbox::OnDestroy->new($$, sub { exit(!!$@) });
		eval {
			my $on_destroy = $self->ipc_atfork_child;
			local %SIG = %SIG;
			wq_worker_loop($self);
		};
		warn "worker $self->{-wq_ident} PID:$$ died: $@" if $@;
		undef $end; # trigger exit
	} else {
		$self->{-wq_workers}->{$pid} = \undef;
	}
}

# starts workqueue workers if Sereal or Storable is installed
sub wq_workers_start {
	my ($self, $ident, $nr_workers, $oldset, $fields) = @_;
	($enc && $send_cmd && $recv_cmd && defined($SEQPACKET)) or return;
	return if $self->{-wq_s1}; # idempotent
	$self->{-wq_s1} = $self->{-wq_s2} = undef;
	socketpair($self->{-wq_s1}, $self->{-wq_s2}, AF_UNIX, $SEQPACKET, 0) or
		die "socketpair: $!";
	$self->ipc_atfork_prepare;
	$nr_workers //= 4;
	$nr_workers = $WQ_MAX_WORKERS if $nr_workers > $WQ_MAX_WORKERS;
	my $sigset = $oldset // PublicInbox::DS::block_signals();
	$self->{-wq_workers} = {};
	$self->{-wq_ident} = $ident;
	_wq_worker_start($self, $sigset, $fields) for (1..$nr_workers);
	PublicInbox::DS::sig_setmask($sigset) unless $oldset;
	$self->{-wq_ppid} = $$;
}

sub wq_worker_incr { # SIGTTIN handler
	my ($self, $oldset, $fields) = @_;
	$self->{-wq_s2} or return;
	return if wq_workers($self) >= $WQ_MAX_WORKERS;
	$self->ipc_atfork_prepare;
	my $sigset = $oldset // PublicInbox::DS::block_signals();
	_wq_worker_start($self, $sigset, $fields);
	PublicInbox::DS::sig_setmask($sigset) unless $oldset;
}

sub wq_exit { # wakes up wq_worker_decr_wait
	send($_[0]->{-wq_s2}, $$, MSG_EOR) // die "$$ send: $!";
	exit;
}

sub wq_worker_decr { # SIGTTOU handler, kills first idle worker
	my ($self) = @_;
	return unless wq_workers($self);
	my $s2 = $self->{-wq_s2} // die 'BUG: no wq_s2';
	$self->wq_do('wq_exit', [ $s2, $s2, $s2 ]);
	# caller must call wq_worker_decr_wait in main loop
}

sub wq_worker_decr_wait {
	my ($self, $timeout) = @_;
	return if $self->{-wq_ppid} != $$; # can't reap siblings or parents
	my $s1 = $self->{-wq_s1} // croak 'BUG: no wq_s1';
	vec(my $rin = '', fileno($s1), 1) = 1;
	select(my $rout = $rin, undef, undef, $timeout) or
		croak 'timed out waiting for wq_exit';
	recv($s1, my $pid, 64, 0) // croak "recv: $!";
	my $workers = $self->{-wq_workers} // croak 'BUG: no wq_workers';
	delete $workers->{$pid} // croak "BUG: PID:$pid invalid";
	dwaitpid($pid, \&ipc_worker_reap, $self);
}

# set or retrieve number of workers
sub wq_workers {
	my ($self, $nr) = @_;
	my $cur = $self->{-wq_workers} or return;
	if (defined $nr) {
		while (scalar(keys(%$cur)) > $nr) {
			$self->wq_worker_decr;
			$self->wq_worker_decr_wait;
		}
		$self->wq_worker_incr while scalar(keys(%$cur)) < $nr;
	}
	scalar(keys(%$cur));
}

sub wq_close {
	my ($self, $nohang) = @_;
	delete @$self{qw(-wq_s1 -wq_s2)} or return;
	my $ppid = delete $self->{-wq_ppid} or return;
	my $workers = delete $self->{-wq_workers} // die 'BUG: no wq_workers';
	return if $ppid != $$; # can't reap siblings or parents
	my @pids = map { $_ + 0 } keys %$workers;
	if ($nohang) {
		push @{$self->{"-wq_old_pids.$$"}}, @pids;
	} else {
		dwaitpid($_, \&ipc_worker_reap, $self) for @pids;
	}
}

sub wq_kill_old {
	my ($self) = @_;
	my $pids = $self->{"-wq_old_pids.$$"} or return;
	kill 'TERM', @$pids;
}

sub wq_kill {
	my ($self, $sig) = @_;
	my $workers = $self->{-wq_workers} or return;
	kill($sig // 'TERM', keys %$workers);
}

sub WQ_MAX_WORKERS { $WQ_MAX_WORKERS }

sub DESTROY {
	my ($self) = @_;
	my $ppid = $self->{-wq_ppid};
	wq_kill($self) if $ppid && $ppid == $$;
	wq_close($self);
	wq_wait_old($self);
	ipc_worker_stop($self);
}

# Sereal doesn't have dclone
sub deep_clone { thaw(freeze($_[-1])) }

1;
