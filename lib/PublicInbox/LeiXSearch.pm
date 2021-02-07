# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Combine any combination of PublicInbox::Search,
# PublicInbox::ExtSearch, and PublicInbox::LeiSearch objects
# into one Xapian DB
package PublicInbox::LeiXSearch;
use strict;
use v5.10.1;
use parent qw(PublicInbox::LeiSearch PublicInbox::IPC);
use PublicInbox::DS qw(now);
use PublicInbox::PktOp qw(pkt_do);
use File::Temp 0.19 (); # 0.19 for ->newdir
use File::Spec ();
use PublicInbox::Search qw(xap_terms);
use PublicInbox::Spawn qw(popen_rd spawn which);
use PublicInbox::MID qw(mids);
use PublicInbox::Smsg;
use Fcntl qw(SEEK_SET F_SETFL O_APPEND O_RDWR);

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
	my $desc = $ibxish->{inboxdir} // $ibxish->{topdir};
	my $srch = $ibxish->search or
		return warn("$desc not indexed for Xapian\n");
	my @shards = $srch->xdb_shards_flat or
		return warn("$desc has no Xapian shards\n");

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
sub locals { @{$_[0]->{locals} // []} }

sub remotes { @{$_[0]->{remotes} // []} }

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
	my $ibx = $self->{shard2ibx}->[$shard];
	my $smsg = $ibx->over->get_art($num);
	if (ref($ibx->can('msg_keywords'))) {
		my $kw = xap_terms('K', $mitem->get_document);
		$smsg->{kw} = [ sort keys %$kw ];
	}
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
	$size >= $mo->{limit} && (($mo->{offset} += $size) < $mo->{limit});
}

# $startq will EOF when query_prepare is done augmenting and allow
# query_mset and query_thread_mset to proceed.
sub wait_startq ($) {
	my ($startq) = @_;
	$_[0] = undef;
	read($startq, my $query_prepare_done, 1);
}

sub mset_progress {
	my $lei = shift;
	return unless $lei->{-progress};
	if ($lei->{pkt_op_p}) {
		pkt_do($lei->{pkt_op_p}, 'mset_progress', @_);
	} else { # single lei-daemon consumer
		my ($desc, $mset_size, $mset_total_est) = @_;
		$lei->{-mset_total} += $mset_size;
		$lei->err("# $desc $mset_size/$mset_total_est");
	}
}

sub query_thread_mset { # for --thread
	my ($self, $ibxish) = @_;
	local $0 = "$0 query_thread_mset";
	my $lei = $self->{lei};
	my $startq = delete $lei->{startq};
	my ($srch, $over) = ($ibxish->search, $ibxish->over);
	my $desc = $ibxish->{inboxdir} // $ibxish->{topdir};
	return warn("$desc not indexed by Xapian\n") unless ($srch && $over);
	my $mo = { %{$lei->{mset_opt}} };
	my $mset;
	my $each_smsg = $lei->{ovv}->ovv_each_smsg_cb($lei, $ibxish);
	do {
		$mset = $srch->mset($mo->{qstr}, $mo);
		mset_progress($lei, $desc, $mset->size,
				$mset->get_matches_estimated);
		my $ids = $srch->mset_to_artnums($mset, $mo);
		my $ctx = { ids => $ids };
		my $i = 0;
		my %n2item = map { ($ids->[$i++], $_) } $mset->items;
		while ($over->expand_thread($ctx)) {
			for my $n (@{$ctx->{xids}}) {
				my $smsg = $over->get_art($n) or next;
				wait_startq($startq) if $startq;
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
	my ($self) = @_;
	local $0 = "$0 query_mset";
	my $lei = $self->{lei};
	my $startq = delete $lei->{startq};
	my $mo = { %{$lei->{mset_opt}} };
	my $mset;
	for my $loc (locals($self)) {
		attach_external($self, $loc);
	}
	my $each_smsg = $lei->{ovv}->ovv_each_smsg_cb($lei, $self);
	do {
		$mset = $self->mset($mo->{qstr}, $mo);
		mset_progress($lei, 'xsearch', $mset->size,
				$mset->size, $mset->get_matches_estimated);
		for my $mitem ($mset->items) {
			my $smsg = smsg_for($self, $mitem) or next;
			wait_startq($startq) if $startq;
			$each_smsg->($smsg, $mitem);
		}
	} while (_mset_more($mset, $mo));
	undef $each_smsg; # drops @io for l2m->{each_smsg_done}
	$lei->{ovv}->ovv_atexit_child($lei);
}

sub each_eml { # callback for MboxReader->mboxrd
	my ($eml, $self, $lei, $each_smsg) = @_;
	my $smsg = bless {}, 'PublicInbox::Smsg';
	$smsg->populate($eml);
	$smsg->parse_references($eml, mids($eml));
	$smsg->{$_} //= '' for qw(from to cc ds subject references mid);
	delete @$smsg{qw(From Subject -ds -ts)};
	if (my $startq = delete($lei->{startq})) { wait_startq($startq) }
	if ($lei->{-progress}) {
		++$lei->{-nr_remote_eml};
		my $now = now();
		my $next = $lei->{-next_progress} //= ($now + 1);
		if ($now > $next) {
			$lei->{-next_progress} = $now + 1;
			my $nr = $lei->{-nr_remote_eml};
			$lei->err("# $lei->{-current_url} $nr/?");
		}
	}
	$each_smsg->($smsg, undef, $eml);
}

sub query_remote_mboxrd {
	my ($self, $uris) = @_;
	local $0 = "$0 query_remote_mboxrd";
	local $SIG{TERM} = sub { exit(0) }; # for DESTROY (File::Temp, $reap)
	my $lei = $self->{lei};
	my ($opt, $env) = @$lei{qw(opt env)};
	my @qform = (q => $lei->{mset_opt}->{qstr}, x => 'm');
	push(@qform, t => 1) if $opt->{thread};
	my $verbose = $opt->{verbose};
	my ($reap_tail, $reap_curl);
	my $cerr = File::Temp->new(TEMPLATE => 'curl.err-XXXX', TMPDIR => 1);
	fcntl($cerr, F_SETFL, O_APPEND|O_RDWR) or warn "set O_APPEND: $!";
	my $rdr = { 2 => $cerr, pgid => 0 };
	my $coff = 0;
	my $sigint_reap = $lei->can('sigint_reap');
	if ($verbose) {
		# spawn a process to force line-buffering, otherwise curl
		# will write 1 character at-a-time and parallel outputs
		# mmmaaayyy llloookkk llliiikkkeee ttthhhiiisss
		my $o = { 1 => $lei->{2}, 2 => $lei->{2}, pgid => 0 };
		my $pid = spawn(['tail', '-f', $cerr->filename], undef, $o);
		$reap_tail = PublicInbox::OnDestroy->new($sigint_reap, $pid);
	}
	my $curl = PublicInbox::LeiCurl->new($lei, $self->{curl}) or return;
	push @$curl, '-s', '-d', '';
	my $each_smsg = $lei->{ovv}->ovv_each_smsg_cb($lei);
	for my $uri (@$uris) {
		$lei->{-current_url} = $uri->as_string;
		$lei->{-nr_remote_eml} = 0;
		$uri->query_form(@qform);
		my $cmd = $curl->for_uri($lei, $uri);
		$lei->err("# @$cmd") if $verbose;
		my ($fh, $pid) = popen_rd($cmd, $env, $rdr);
		$reap_curl = PublicInbox::OnDestroy->new($sigint_reap, $pid);
		$fh = IO::Uncompress::Gunzip->new($fh);
		PublicInbox::MboxReader->mboxrd($fh, \&each_eml, $self,
						$lei, $each_smsg);
		my $err = waitpid($pid, 0) == $pid ? undef : "BUG: waitpid: $!";
		@$reap_curl = (); # cancel OnDestroy
		die $err if $err;
		if ($? == 0) {
			my $nr = $lei->{-nr_remote_eml};
			mset_progress($lei, $lei->{-current_url}, $nr, $nr);
			next;
		}
		seek($cerr, $coff, SEEK_SET) or warn "seek(curl stderr): $!\n";
		my $e = do { local $/; <$cerr> } //
				die "read(curl stderr): $!\n";
		$coff += length($e);
		truncate($cerr, 0);
		next if (($? >> 8) == 22 && $e =~ /\b404\b/);
		$lei->child_error($?);
		$uri->query_form(q => $lei->{mset_opt}->{qstr});
		# --verbose already showed the error via tail(1)
		$lei->err("E: $uri \$?=$?\n", $verbose ? () : $e);
	}
	undef $each_smsg;
	$lei->{ovv}->ovv_atexit_child($lei);
}

# called by LeiOverview::each_smsg_cb
sub git { $_[0]->{git_tmp} // die 'BUG: caller did not set {git_tmp}' }

sub git_tmp ($) {
	my ($self) = @_;
	my (%seen, @dirs);
	my $tmp = File::Temp->newdir("lei_xsearch_git.$$-XXXX", TMPDIR => 1);
	for my $ibxish (locals($self)) {
		my $d = File::Spec->canonpath($ibxish->git->{git_dir});
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

sub xsearch_done_wait { # dwaitpid callback
	my ($arg, $pid) = @_;
	my ($wq, $lei) = @$arg;
	$lei->child_error($?, 'non-fatal error from '.ref($wq)) if $?;
}

sub query_done { # EOF callback for main daemon
	my ($lei) = @_;
	my $l2m = delete $lei->{l2m};
	$l2m->wq_wait_old(\&xsearch_done_wait, $lei) if $l2m;
	if (my $lxs = delete $lei->{lxs}) {
		$lxs->wq_wait_old(\&xsearch_done_wait, $lei);
	}
	$lei->{ovv}->ovv_end($lei);
	if ($l2m) { # close() calls LeiToMail reap_compress
		if (my $out = delete $lei->{old_1}) {
			if (my $mbout = $lei->{1}) {
				close($mbout) or return $lei->fail(<<"");
Error closing $lei->{ovv}->{dst}: $!

			}
			$lei->{1} = $out;
		}
		$l2m->lock_free ? $l2m->poke_dst : $lei->start_mua;
	}
	$lei->{-progress} and
		$lei->err('# ', $lei->{-mset_total} // 0, " matches");
	$lei->dclose;
}

sub do_post_augment {
	my ($lei) = @_;
	eval { $lei->{l2m}->post_augment($lei) };
	if (my $err = $@) {
		if (my $lxs = delete $lei->{lxs}) {
			$lxs->wq_kill;
			$lxs->wq_close(0, undef, $lei);
		}
		$lei->fail("$err");
	}
	close(delete $lei->{au_done}); # triggers wait_startq
}

my $MAX_PER_HOST = 4;

sub concurrency {
	my ($self, $opt) = @_;
	my $nl = $opt->{thread} ? locals($self) : 1;
	my $nr = remotes($self);
	$nr = $MAX_PER_HOST if $nr > $MAX_PER_HOST;
	$nl + $nr;
}

sub start_query { # always runs in main (lei-daemon) process
	my ($self, $lei) = @_;
	if (my $l2m = $lei->{l2m}) {
		$lei->start_mua if $l2m->lock_free;
	}
	if ($lei->{opt}->{thread}) {
		for my $ibxish (locals($self)) {
			$self->wq_io_do('query_thread_mset', [], $ibxish);
		}
	} elsif (locals($self)) {
		$self->wq_io_do('query_mset', []);
	}
	my $i = 0;
	my $q = [];
	for my $uri (remotes($self)) {
		push @{$q->[$i++ % $MAX_PER_HOST]}, $uri;
	}
	for my $uris (@$q) {
		$self->wq_io_do('query_remote_mboxrd', [], $uris);
	}
}

sub ipc_atfork_child {
	my ($self) = @_;
	$self->{lei}->lei_atfork_child;
	$self->SUPER::ipc_atfork_child;
}

sub query_prepare { # called by wq_io_do
	my ($self) = @_;
	local $0 = "$0 query_prepare";
	my $lei = $self->{lei};
	eval { $lei->{l2m}->do_augment($lei) };
	$lei->fail($@) if $@;
	pkt_do($lei->{pkt_op_p}, '.') == 1 or die "do_post_augment trigger: $!"
}

sub do_query {
	my ($self, $lei) = @_;
	my $ops = {
		'|' => [ $lei->can('sigpipe_handler'), $lei ],
		'!' => [ $lei->can('fail_handler'), $lei ],
		'.' => [ \&do_post_augment, $lei ],
		'' => [ \&query_done, $lei ],
		'mset_progress' => [ \&mset_progress, $lei ],
		'x_it' => [ $lei->can('x_it'), $lei ],
		'child_error' => [ $lei->can('child_error'), $lei ],
	};
	($lei->{pkt_op_c}, $lei->{pkt_op_p}) = PublicInbox::PktOp->pair($ops);
	$lei->{1}->autoflush(1);
	$lei->start_pager if delete $lei->{need_pager};
	$lei->{ovv}->ovv_begin($lei);
	my $l2m = $lei->{l2m};
	if ($l2m) {
		$l2m->pre_augment($lei);
		$l2m->wq_workers_start('lei2mail', $l2m->{jobs},
					$lei->oldset, { lei => $lei });
		pipe($lei->{startq}, $lei->{au_done}) or die "pipe: $!";
		# 1031: F_SETPIPE_SZ
		fcntl($lei->{startq}, 1031, 4096) if $^O eq 'linux';
	}
	if (!$lei->{opt}->{thread} && locals($self)) { # for query_mset
		# lei->{git_tmp} is set for wq_wait_old so we don't
		# delete until all lei2mail + lei_xsearch workers are reaped
		$lei->{git_tmp} = $self->{git_tmp} = git_tmp($self);
	}
	$self->wq_workers_start('lei_xsearch', $self->{jobs},
				$lei->oldset, { lei => $lei });
	my $op = delete $lei->{pkt_op_c};
	delete $lei->{pkt_op_p};
	$l2m->wq_close(1) if $l2m;
	$lei->event_step_init; # wait for shutdowns
	$self->wq_io_do('query_prepare', []) if $l2m;
	start_query($self, $lei);
	$self->wq_close(1); # lei_xsearch workers stop when done
	if ($lei->{oneshot}) {
		while ($op->{sock}) { $op->event_step }
	}
}

sub add_uri {
	my ($self, $uri) = @_;
	if (my $curl = $self->{curl} //= which('curl') // 0) {
		require PublicInbox::MboxReader;
		require IO::Uncompress::Gunzip;
		require PublicInbox::LeiCurl;
		push @{$self->{remotes}}, $uri;
	} else {
		warn "curl missing, ignoring $uri\n";
	}
}

sub prepare_external {
	my ($self, $loc, $boost) = @_; # n.b. already ordered by boost
	if (ref $loc) { # already a URI, or PublicInbox::Inbox-like object
		return add_uri($self, $loc) if $loc->can('scheme');
	} elsif ($loc =~ m!\Ahttps?://!) {
		require URI;
		return add_uri($self, URI->new($loc));
	} elsif (-f "$loc/ei.lock") {
		require PublicInbox::ExtSearch;
		$loc = PublicInbox::ExtSearch->new($loc);
	} elsif (-f "$loc/inbox.lock" || -d "$loc/public-inbox") {
		require PublicInbox::Inbox; # v2, v1
		$loc = bless { inboxdir => $loc }, 'PublicInbox::Inbox';
	} else {
		warn "W: ignoring $loc, unable to determine type\n";
		return;
	}
	push @{$self->{locals}}, $loc;
}


1;
