# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# base class for remote IPC calls and workqueues, requires Storable or Sereal
# - ipc_do and ipc_worker_* is for a single worker/producer and uses pipes
# - wq_io_do and wq_worker* is for a single producer and multiple workers,
#   using SOCK_SEQPACKET for work distribution
# use ipc_do when you need work done on a certain process
# use wq_io_do when your work can be done on any idle worker
package PublicInbox::IPC;
use strict;
use v5.10.1;
use parent qw(Exporter);
use Carp qw(croak);
use PublicInbox::DS qw(dwaitpid);
use PublicInbox::Spawn;
use PublicInbox::OnDestroy;
use PublicInbox::WQWorker;
use Socket qw(AF_UNIX MSG_EOR SOCK_STREAM);
my $MY_MAX_ARG_STRLEN = 4096 * 33; # extra 4K for serialization
my $SEQPACKET = eval { Socket::SOCK_SEQPACKET() }; # portable enough?
our @EXPORT_OK = qw(ipc_freeze ipc_thaw);
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
	*ipc_freeze = sub ($) { sereal_encode_with_object $enc, $_[0] };
	*ipc_thaw = sub ($) { sereal_decode_with_object $dec, $_[0], my $ret };
} else {
	require Storable;
	*ipc_freeze = \&Storable::freeze;
	*ipc_thaw = \&Storable::thaw;
}

my $recv_cmd = PublicInbox::Spawn->can('recv_cmd4');
my $send_cmd = PublicInbox::Spawn->can('send_cmd4') // do {
	require PublicInbox::CmdIPC4;
	$recv_cmd //= PublicInbox::CmdIPC4->can('recv_cmd4');
	PublicInbox::CmdIPC4->can('send_cmd4');
} // do {
	require PublicInbox::Syscall;
	$recv_cmd //= PublicInbox::Syscall->can('recv_cmd4');
	PublicInbox::Syscall->can('send_cmd4');
};

sub _get_rec ($) {
	my ($r) = @_;
	defined(my $len = <$r>) or return;
	chop($len) eq "\n" or croak "no LF byte in $len";
	defined(my $n = read($r, my $buf, $len)) or croak "read error: $!";
	$n == $len or croak "short read: $n != $len";
	ipc_thaw($buf);
}

sub _send_rec ($$) {
	my ($w, $ref) = @_;
	my $buf = ipc_freeze($ref);
	print $w length($buf), "\n", $buf or croak "print: $!";
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
	my ($self, $ident, $oldset, $fields) = @_;
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
		eval { Net::SSLeay::randomize() };
		eval { PublicInbox::DS->Reset };
		delete @$self{qw(-wq_s1 -wq_s2 -wq_workers -wq_ppid)};
		$w_req = $r_res = undef;
		$w_res->autoflush(1);
		$SIG{$_} = 'IGNORE' for (qw(TERM INT QUIT));
		local $0 = $ident;
		# ensure we properly exit even if warn() dies:
		my $end = PublicInbox::OnDestroy->new($$, sub { exit(!!$@) });
		eval {
			$fields //= {};
			local @$self{keys %$fields} = values(%$fields);
			my $on_destroy = $self->ipc_atfork_child;
			local @SIG{keys %SIG} = values %SIG;
			PublicInbox::DS::sig_setmask($sigset);
			ipc_worker_loop($self, $r_req, $w_res);
		};
		warn "worker $ident PID:$$ died: $@\n" if $@;
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
	my ($args, $pid) = @_;
	my ($self, @uargs) = @$args;
	delete $self->{-wq_workers}->{$pid};
	return $self->{-reap_do}->($args, $pid) if $self->{-reap_do};
	return if !$?;
	my $s = $? & 127;
	# TERM(15) is our default exit signal, PIPE(13) is likely w/ pager
	warn "$self->{-wq_ident} PID:$pid died \$?=$?\n" if $s != 15 && $s != 13
}

sub wq_wait_async {
	my ($self, $cb, @uargs) = @_;
	local $PublicInbox::DS::in_loop = 1;
	$self->{-reap_async} = 1;
	$self->{-reap_do} = $cb;
	my @pids = keys %{$self->{-wq_workers}};
	dwaitpid($_, \&ipc_worker_reap, [ $self, @uargs ]) for @pids;
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
	my ($self, $args) = @_;
	my ($pid, $ppid) = delete(@$self{qw(-ipc_pid -ipc_ppid)});
	my ($w_req, $r_res) = delete(@$self{qw(-ipc_req -ipc_res)});
	if (!$w_req && !$r_res) {
		die "unexpected PID:$pid without IPC pipes" if $pid;
		return; # idempotent
	}
	die 'no PID with IPC pipes' unless $pid;
	$w_req = $r_res = undef;

	return if $$ != $ppid;
	dwaitpid($pid, \&ipc_worker_reap, [$self, $args]);
}

# use this if we have multiple readers reading curl or "pigz -dc"
# and writing to the same store
sub ipc_lock_init {
	my ($self, $f) = @_;
	$f // die 'BUG: no filename given';
	require PublicInbox::Lock;
	$self->{-ipc_lock} //= bless { lock_path => $f }, 'PublicInbox::Lock'
}

sub _wait_return ($$) {
	my ($r_res, $sub) = @_;
	my $ret = _get_rec($r_res) // die "no response on $sub";
	die $$ret if ref($ret) eq 'PublicInbox::IPC::Die';
	wantarray ? @$ret : $$ret;
}

# call $self->$sub(@args), on a worker if ipc_worker_spawn was used
sub ipc_do {
	my ($self, $sub, @args) = @_;
	if (my $w_req = $self->{-ipc_req}) { # run in worker
		my $ipc_lock = $self->{-ipc_lock};
		my $lock = $ipc_lock ? $ipc_lock->lock_for_scope : undef;
		if (defined(wantarray)) {
			my $r_res = $self->{-ipc_res} or die 'no ipc_res';
			_send_rec($w_req, [ wantarray, $sub, @args ]);
			_wait_return($r_res, $sub);
		} else { # likely, fire-and-forget into pipe
			_send_rec($w_req, [ undef , $sub, @args ]);
		}
	} else { # run locally
		$self->$sub(@args);
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
	my @fds = $recv_cmd->($s2, my $buf, $len // $MY_MAX_ARG_STRLEN);
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
	my $args = ipc_thaw($buf) // die "thaw error on buffer of size: $n";
	undef $buf;
	my $sub = shift @$args;
	eval { $self->$sub(@$args) };
	warn "$$ $0 wq_worker: $sub: $@" if $@;
	delete @$self{0..($nfd-1)};
	$n;
}

sub wq_worker_loop ($$) {
	my ($self, $bcast2) = @_;
	my $wqw = PublicInbox::WQWorker->new($self, $self->{-wq_s2});
	PublicInbox::WQWorker->new($self, $bcast2) if $bcast2;
	PublicInbox::DS->SetPostLoopCallback(sub { $wqw->{sock} });
	PublicInbox::DS::event_loop();
	PublicInbox::DS->Reset;
}

sub do_sock_stream { # via wq_io_do, for big requests
	my ($self, $len) = @_;
	recv_and_run($self, my $s2 = delete $self->{0}, $len, 1);
}

sub wq_broadcast {
	my ($self, $sub, @args) = @_;
	if (my $wkr = $self->{-wq_workers}) {
		my $buf = ipc_freeze([$sub, @args]);
		for my $bcast1 (values %$wkr) {
			my $sock = $bcast1 // $self->{-wq_s1} // next;
			send($sock, $buf, MSG_EOR) // croak "send: $!";
			# XXX shouldn't have to deal with EMSGSIZE here...
		}
	} else {
		eval { $self->$sub(@args) };
		warn "wq_broadcast: $@" if $@;
	}
}

sub stream_in_full ($$$) {
	my ($s1, $fds, $buf) = @_;
	socketpair(my $r, my $w, AF_UNIX, SOCK_STREAM, 0) or
		croak "socketpair: $!";
	my $n = $send_cmd->($s1, [ fileno($r) ],
			ipc_freeze(['do_sock_stream', length($buf)]),
			MSG_EOR) // croak "sendmsg: $!";
	undef $r;
	$n = $send_cmd->($w, $fds, $buf, 0) // croak "sendmsg: $!";
	while ($n < length($buf)) {
		my $x = syswrite($w, $buf, length($buf) - $n, $n) //
				croak "syswrite: $!";
		croak "syswrite wrote 0 bytes" if $x == 0;
		$n += $x;
	}
}

sub wq_io_do { # always async
	my ($self, $sub, $ios, @args) = @_;
	if (my $s1 = $self->{-wq_s1}) { # run in worker
		my $fds = [ map { fileno($_) } @$ios ];
		my $buf = ipc_freeze([$sub, @args]);
		if (length($buf) > $MY_MAX_ARG_STRLEN) {
			stream_in_full($s1, $fds, $buf);
		} else {
			my $n = $send_cmd->($s1, $fds, $buf, MSG_EOR);
			return if defined($n); # likely
			$!{ETOOMANYREFS} and
				croak "sendmsg: $! (check RLIMIT_NOFILE)";
			$!{EMSGSIZE} ? stream_in_full($s1, $fds, $buf) :
				croak("sendmsg: $!");
		}
	} else {
		@$self{0..$#$ios} = @$ios;
		eval { $self->$sub(@args) };
		warn "wq_io_do: $@" if $@;
		delete @$self{0..$#$ios}; # don't close
	}
}

sub wq_sync_run {
	my ($self, $wantarray, $sub, @args) = @_;
	if ($wantarray) {
		my @ret = eval { $self->$sub(@args) };
		ipc_return($self->{0}, \@ret, $@);
	} else { # '' => wantscalar
		my $ret = eval { $self->$sub(@args) };
		ipc_return($self->{0}, \$ret, $@);
	}
}

sub wq_do {
	my ($self, $sub, @args) = @_;
	if (defined(wantarray)) {
		pipe(my ($r, $w)) or die "pipe: $!";
		wq_io_do($self, 'wq_sync_run', [ $w ], wantarray, $sub, @args);
		undef $w;
		_wait_return($r, $sub);
	} else {
		wq_io_do($self, $sub, [], @args);
	}
}

sub _wq_worker_start ($$$$) {
	my ($self, $oldset, $fields, $one) = @_;
	my ($bcast1, $bcast2);
	$one or socketpair($bcast1, $bcast2, AF_UNIX, $SEQPACKET, 0) or
							die "socketpair: $!";
	my $seed = rand(0xffffffff);
	my $pid = fork // die "fork: $!";
	if ($pid == 0) {
		srand($seed);
		eval { Net::SSLeay::randomize() };
		undef $bcast1;
		eval { PublicInbox::DS->Reset };
		delete @$self{qw(-wq_s1 -wq_ppid)};
		$self->{-wq_worker_nr} =
				keys %{delete($self->{-wq_workers}) // {}};
		$SIG{$_} = 'DEFAULT' for (qw(TTOU TTIN TERM QUIT INT CHLD));
		local $0 = $one ? $self->{-wq_ident} :
			"$self->{-wq_ident} $self->{-wq_worker_nr}";
		# ensure we properly exit even if warn() dies:
		my $end = PublicInbox::OnDestroy->new($$, sub { exit(!!$@) });
		eval {
			$fields //= {};
			local @$self{keys %$fields} = values(%$fields);
			my $on_destroy = $self->ipc_atfork_child;
			local @SIG{keys %SIG} = values %SIG;
			PublicInbox::DS::sig_setmask($oldset);
			wq_worker_loop($self, $bcast2);
		};
		warn "worker $self->{-wq_ident} PID:$$ died: $@" if $@;
		undef $end; # trigger exit
	} else {
		$self->{-wq_workers}->{$pid} = $bcast1;
	}
}

# starts workqueue workers if Sereal or Storable is installed
sub wq_workers_start {
	my ($self, $ident, $nr_workers, $oldset, $fields) = @_;
	($send_cmd && $recv_cmd && defined($SEQPACKET)) or return;
	return if $self->{-wq_s1}; # idempotent
	$self->{-wq_s1} = $self->{-wq_s2} = undef;
	socketpair($self->{-wq_s1}, $self->{-wq_s2}, AF_UNIX, $SEQPACKET, 0) or
		die "socketpair: $!";
	$self->ipc_atfork_prepare;
	$nr_workers //= $self->{-wq_nr_workers}; # was set earlier
	my $sigset = $oldset // PublicInbox::DS::block_signals();
	$self->{-wq_workers} = {};
	$self->{-wq_ident} = $ident;
	my $one = $nr_workers == 1;
	$self->{-wq_nr_workers} = $nr_workers;
	_wq_worker_start($self, $sigset, $fields, $one) for (1..$nr_workers);
	PublicInbox::DS::sig_setmask($sigset) unless $oldset;
	$self->{-wq_ppid} = $$;
}

sub wq_close {
	my ($self) = @_;
	delete @$self{qw(-wq_s1 -wq_s2)} or return;
	return if $self->{-reap_async};
	my @pids = keys %{$self->{-wq_workers}};
	dwaitpid($_, \&ipc_worker_reap, [ $self ]) for @pids;
}

sub wq_kill {
	my ($self, $sig) = @_;
	kill($sig // 'TERM', keys %{$self->{-wq_workers}});
}

sub DESTROY {
	my ($self) = @_;
	my $ppid = $self->{-wq_ppid};
	wq_kill($self) if $ppid && $ppid == $$;
	wq_close($self);
	ipc_worker_stop($self);
}

sub detect_nproc () {
	# _SC_NPROCESSORS_ONLN = 84 on both Linux glibc and musl
	return POSIX::sysconf(84) if $^O eq 'linux';
	return POSIX::sysconf(58) if $^O eq 'freebsd';
	# TODO: more OSes

	# getconf(1) is POSIX, but *NPROCESSORS* vars are not
	for (qw(_NPROCESSORS_ONLN NPROCESSORS_ONLN)) {
		`getconf $_ 2>/dev/null` =~ /^(\d+)$/ and return $1;
	}
	for my $nproc (qw(nproc gnproc)) { # GNU coreutils nproc
		`$nproc 2>/dev/null` =~ /^(\d+)$/ and return $1;
	}

	# should we bother with `sysctl hw.ncpu`?  Those only give
	# us total processor count, not online processor count.
	undef
}

1;
