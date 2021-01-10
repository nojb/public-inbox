# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# base class for remote IPC calls, requires Storable
# TODO: this ought to be usable in SearchIdxShard
package PublicInbox::IPC;
use strict;
use v5.10.1;
use Carp qw(confess croak);
use PublicInbox::Sigfd;
use POSIX ();
use constant PIPE_BUF => $^O eq 'linux' ? 4096 : POSIX::_POSIX_PIPE_BUF();
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
			eval { warn "$$ die: $@ (from nowait $sub)\n" } if $@;
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
	my $parent = $$;
	$self->ipc_atfork_parent;
	defined(my $pid = fork) or die "fork: $!";
	if ($pid == 0) {
		eval { PublicInbox::DS->Reset };
		$self->{-ipc_parent_pid} = $parent;
		$w_req = $r_res = undef;
		$w_res->autoflush(1);
		$SIG{$_} = 'IGNORE' for (qw(TERM INT QUIT));
		local $0 = $ident;
		PublicInbox::DS::sig_setmask($oldset);
		my $on_destroy = $self->ipc_atfork_child;
		eval { ipc_worker_loop($self, $r_req, $w_res) };
		die "worker $ident PID:$$ died: $@\n" if $@;
		exit;
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
	warn "PID:$pid died with \$?=$?\n" if $?;
}

# for base class, override in sub classes
sub ipc_atfork_parent {}
sub ipc_atfork_child {}

# should only be called inside the worker process
sub ipc_worker_exit {
	my (undef, $code) = @_;
	exit($code);
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
	_send_rec($w_req, [ undef, 'ipc_worker_exit', 0 ]);
	$w_req = $r_res = undef;

	# allow any sibling to send ipc_worker_exit, but siblings can't wait
	return if $$ != $ppid;
	eval {
		my $reap = $self->can('ipc_worker_reap');
		PublicInbox::DS::dwaitpid($pid, $reap, $self);
	};
	if ($@) {
		my $wp = waitpid($pid, 0);
		$pid == $wp or die "waitpid($pid) returned $wp: \$?=$?";
		$self->ipc_worker_reap($pid);
	}
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

1;
