# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Combine any combination of PublicInbox::Search,
# PublicInbox::ExtSearch, and PublicInbox::LeiSearch objects
# into one Xapian DB
package PublicInbox::LeiXSearch;
use strict;
use v5.10.1;
use parent qw(PublicInbox::LeiSearch PublicInbox::IPC);
use PublicInbox::DS qw(dwaitpid);
use PublicInbox::OpPipe;
use PublicInbox::Import;
use File::Temp 0.19 (); # 0.19 for ->newdir
use File::Spec ();

sub new {
	my ($class) = @_;
	PublicInbox::Search::load_xapian();
	bless {
		qp_flags => $PublicInbox::Search::QP_FLAGS |
				PublicInbox::Search::FLAG_PURE_NOT(),
	}, $class
}

sub attach_external {
	my ($self, $ibxish) = @_; # ibxish = ExtSearch or Inbox

	if (!$ibxish->can('over') || !$ibxish->over) {
		return push(@{$self->{remotes}}, $ibxish)
	}
	my $desc = $ibxish->{inboxdir} // $ibxish->{topdir};
	my $srch = $ibxish->search or
		return warn("$desc not indexed for Xapian\n");
	my @shards = $srch->xdb_shards_flat or
		return warn("$desc has no Xapian shardsXapian\n");

	if (delete $self->{xdb}) { # XXX: do we need this?
		# clobber existing {xdb} if amending
		my $expect = delete $self->{nshard};
		my $shards = delete $self->{shards_flat};
		scalar(@$shards) == $expect or die
			"BUG: {nshard}$expect != shards=".scalar(@$shards);

		my $prev = {};
		for my $old_ibxish (@{$self->{shard2ibx}}) {
			next if $prev == $old_ibxish;
			$prev = $old_ibxish;
			my @shards = $old_ibxish->search->xdb_shards_flat;
			push @{$self->{shards_flat}}, @shards;
		}
		my $nr = scalar(@{$self->{shards_flat}});
		$nr == $expect or die
			"BUG: reloaded $nr shards, expected $expect"
	}
	push @{$self->{shards_flat}}, @shards;
	push(@{$self->{shard2ibx}}, $ibxish) for (@shards);
}

# returns a list of local inboxes (or count in scalar context)
sub locals {
	my %uniq = map {; "$_" => $_ } @{$_[0]->{shard2ibx} // []};
	values %uniq;
}

# called by PublicInbox::Search::xdb
sub xdb_shards_flat { @{$_[0]->{shards_flat} // []} }

# like over->get_art
sub smsg_for {
	my ($self, $mitem) = @_;
	# cf. https://trac.xapian.org/wiki/FAQ/MultiDatabaseDocumentID
	my $nshard = $self->{nshard};
	my $docid = $mitem->get_docid;
	my $shard = ($docid - 1) % $nshard;
	my $num = int(($docid - 1) / $nshard) + 1;
	my $smsg = $self->{shard2ibx}->[$shard]->over->get_art($num);
	$smsg->{docid} = $docid;
	$smsg;
}

sub recent {
	my ($self, $qstr, $opt) = @_;
	$opt //= {};
	$opt->{relevance} //= -2;
	$self->mset($qstr //= 'bytes:1..', $opt);
}

sub over {}

sub _mset_more ($$) {
	my ($mset, $mo) = @_;
	my $size = $mset->size;
	$size && (($mo->{offset} += $size) < ($mo->{limit} // 10000));
}

# $startq will EOF when query_prepare is done augmenting and allow
# query_mset and query_thread_mset to proceed.
sub wait_startq ($) {
	my ($startq) = @_;
	$_[0] = undef;
	read($startq, my $query_prepare_done, 1);
}

sub query_thread_mset { # for --thread
	my ($self, $lei, $ibxish) = @_;
	my $startq = delete $self->{5};
	my %sig = $lei->atfork_child_wq($self);
	local @SIG{keys %sig} = values %sig;

	my ($srch, $over) = ($ibxish->search, $ibxish->over);
	unless ($srch && $over) {
		my $desc = $ibxish->{inboxdir} // $ibxish->{topdir};
		warn "$desc not indexed by Xapian\n";
		return;
	}
	my $mo = { %{$lei->{mset_opt}} };
	my $mset;
	my $each_smsg = $lei->{ovv}->ovv_each_smsg_cb($lei, $ibxish);
	my $dedupe = $lei->{dedupe} // die 'BUG: {dedupe} missing';
	$dedupe->prepare_dedupe;
	do {
		$mset = $srch->mset($mo->{qstr}, $mo);
		my $ids = $srch->mset_to_artnums($mset, $mo);
		my $ctx = { ids => $ids };
		my $i = 0;
		my %n2item = map { ($ids->[$i++], $_) } $mset->items;
		while ($over->expand_thread($ctx)) {
			for my $n (@{$ctx->{xids}}) {
				my $smsg = $over->get_art($n) or next;
				wait_startq($startq) if $startq;
				next if $dedupe->is_smsg_dup($smsg);
				my $mitem = delete $n2item{$smsg->{num}};
				$each_smsg->($smsg, $mitem);
			}
			@{$ctx->{xids}} = ();
		}
	} while (_mset_more($mset, $mo));
	undef $each_smsg; # drops @io for l2m->{each_smsg_done}
	$lei->{ovv}->ovv_atexit_child($lei);
}

sub query_mset { # non-parallel for non-"--thread" users
	my ($self, $lei, $srcs) = @_;
	my $startq = delete $self->{5};
	my %sig = $lei->atfork_child_wq($self);
	local @SIG{keys %sig} = values %sig;
	my $mo = { %{$lei->{mset_opt}} };
	my $mset;
	$self->attach_external($_) for @$srcs;
	my $each_smsg = $lei->{ovv}->ovv_each_smsg_cb($lei, $self);
	my $dedupe = $lei->{dedupe} // die 'BUG: {dedupe} missing';
	$dedupe->prepare_dedupe;
	do {
		$mset = $self->mset($mo->{qstr}, $mo);
		for my $it ($mset->items) {
			my $smsg = smsg_for($self, $it) or next;
			wait_startq($startq) if $startq;
			next if $dedupe->is_smsg_dup($smsg);
			$each_smsg->($smsg, $it);
		}
	} while (_mset_more($mset, $mo));
	undef $each_smsg; # drops @io for l2m->{each_smsg_done}
	$lei->{ovv}->ovv_atexit_child($lei);
}

sub git {
	my ($self) = @_;
	my (%seen, @dirs);
	my $tmp = File::Temp->newdir('lei_xsrch_git-XXXXXXXX', TMPDIR => 1);
	for my $ibx (@{$self->{shard2ibx} // []}) {
		my $d = File::Spec->canonpath($ibx->git->{git_dir});
		$seen{$d} //= push @dirs, "$d/objects\n"
	}
	my $git_dir = $tmp->dirname;
	PublicInbox::Import::init_bare($git_dir);
	my $f = "$git_dir/objects/info/alternates";
	open my $alt, '>', $f or die "open($f): $!";
	print $alt @dirs or die "print $f: $!";
	close $alt or die "close $f: $!";
	my $git = PublicInbox::Git->new($git_dir);
	$git->{-tmp} = $tmp;
	$git;
}

sub query_done { # EOF callback
	my ($self, $lei) = @_;
	my $l2m = delete $lei->{l2m};
	if (my $pids = delete $self->{l2m_pids}) {
		my $ipc_worker_reap = $self->can('ipc_worker_reap');
		dwaitpid($_, $ipc_worker_reap, $l2m) for @$pids;
	}
	$lei->{ovv}->ovv_end($lei);
	$lei->start_mua if $l2m;
	$lei->dclose;
}

sub start_query { # always runs in main (lei-daemon) process
	my ($self, $io, $lei, $srcs) = @_;
	if (my $l2m = $lei->{l2m}) {
		$lei->{1} = $io->[1];
		$l2m->post_augment($lei);
		$io->[1] = delete $lei->{1};
	}
	my $remotes = $self->{remotes} // [];
	if ($lei->{opt}->{thread}) {
		for my $ibxish (@$srcs) {
			$self->wq_do('query_thread_mset', $io, $lei, $ibxish);
		}
	} else {
		$self->wq_do('query_mset', $io, $lei, $srcs);
	}
	# TODO
	for my $rmt (@$remotes) {
		$self->wq_do('query_thread_mbox', $io, $lei, $rmt);
	}
	close $io->[0]; # qry_status_wr
	@$io = ();
}

sub query_prepare { # called by wq_do
	my ($self, $lei) = @_;
	my %sig = $lei->atfork_child_wq($self);
	local @SIG{keys %sig} = values %sig;
	eval { $lei->{l2m}->do_augment($lei) };
	$lei->fail($@) if $@;
}

sub sigpipe_handler {
	my ($self, $lei_orig, $pids) = @_;
	if ($pids) { # one-shot (no event loop)
		kill 'TERM', @$pids;
		kill 'PIPE', $$;
	} else {
		$self->wq_kill;
		$self->wq_close;
	}
	close(delete $lei_orig->{1}) if $lei_orig->{1};
}

sub do_query {
	my ($self, $lei_orig, $srcs) = @_;
	my ($lei, @io) = $lei_orig->atfork_parent_wq($self);
	$io[0] = undef;
	pipe(my $done, $io[0]) or die "pipe $!";

	$lei_orig->event_step_init; # wait for shutdowns
	my $done_op = {
		'' => [ \&query_done, $self, $lei_orig ],
		'!' => [ \&sigpipe_handler, $self, $lei_orig ]
	};
	my $in_loop = exists $lei_orig->{sock};
	$done = PublicInbox::OpPipe->new($done, $done_op, $in_loop);
	my $l2m = $lei->{l2m};
	if ($l2m) {
		$l2m->pre_augment($lei_orig); # may redirect $lei->{1} for mbox
		$io[1] = $lei_orig->{1};
		my @l2m_io = (undef, @io[1..$#io]);
		pipe(my $startq, $l2m_io[0]) or die "pipe: $!";
		$self->wq_do('query_prepare', \@l2m_io, $lei);
		$io[4] = *STDERR{GLOB}; # don't send l2m->{-wq_s1}
		die "BUG: unexpected \$io[5]: $io[5]" if $io[5];
		fcntl($startq, 1031, 4096) if $^O eq 'linux'; # F_SETPIPE_SZ
		$io[5] = $startq;
	}
	start_query($self, \@io, $lei, $srcs);
	unless ($in_loop) {
		my @pids = $self->wq_close;
		# for the $lei->atfork_child_wq PIPE handler:
		$done_op->{'!'}->[3] = \@pids;
		$done->event_step;
		my $ipc_worker_reap = $self->can('ipc_worker_reap');
		if (my $l2m_pids = delete $self->{l2m_pids}) {
			dwaitpid($_, $ipc_worker_reap, $l2m) for @$l2m_pids;
		}
		dwaitpid($_, $ipc_worker_reap, $self) for @pids;
	}
}

sub ipc_atfork_prepare {
	my ($self) = @_;
	# (0: qry_status_wr, 1: stdout|mbox, 2: stderr,
	#  3: sock, 4: $l2m->{-wq_s1}, 5: $startq)
	$self->wq_set_recv_modes(qw[+<&= >&= >&= +<&= +<&= <&=]);
	$self->SUPER::ipc_atfork_prepare; # PublicInbox::IPC
}

1;
