# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Combine any combination of PublicInbox::Search,
# PublicInbox::ExtSearch, and PublicInbox::LeiSearch objects
# into one Xapian DB
package PublicInbox::LeiXSearch;
use strict;
use v5.10.1;
use parent qw(PublicInbox::LeiSearch PublicInbox::IPC);
use PublicInbox::DS qw(dwaitpid now);
use PublicInbox::PktOp qw(pkt_do);
use PublicInbox::Import;
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

sub query_thread_mset { # for --thread
	my ($self, $lei, $ibxish) = @_;
	local $0 = "$0 query_thread_mset";
	$lei->atfork_child_wq($self);
	my $startq = delete $lei->{startq};

	my ($srch, $over) = ($ibxish->search, $ibxish->over);
	my $desc = $ibxish->{inboxdir} // $ibxish->{topdir};
	return warn("$desc not indexed by Xapian\n") unless ($srch && $over);
	my $mo = { %{$lei->{mset_opt}} };
	my $mset;
	my $each_smsg = $lei->{ovv}->ovv_each_smsg_cb($lei, $ibxish);
	do {
		$mset = $srch->mset($mo->{qstr}, $mo);
		pkt_do($lei->{pkt_op}, 'mset_progress', $desc, $mset->size,
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
	my ($self, $lei) = @_;
	local $0 = "$0 query_mset";
	$lei->atfork_child_wq($self);
	my $startq = delete $lei->{startq};
	my $mo = { %{$lei->{mset_opt}} };
	my $mset;
	for my $loc (locals($self)) {
		attach_external($self, $loc);
	}
	my $each_smsg = $lei->{ovv}->ovv_each_smsg_cb($lei, $self);
	do {
		$mset = $self->mset($mo->{qstr}, $mo);
		pkt_do($lei->{pkt_op}, 'mset_progress', 'xsearch',
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
	++$lei->{-nr_remote_eml};
	if (!$lei->{opt}->{quiet}) {
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

# PublicInbox::OnDestroy callback
sub kill_reap {
	my ($pid) = @_;
	kill('KILL', $pid); # spawn() blocks other signals
	waitpid($pid, 0);
}

sub query_remote_mboxrd {
	my ($self, $lei, $uris) = @_;
	local $0 = "$0 query_remote_mboxrd";
	$lei->atfork_child_wq($self);
	my ($opt, $env) = @$lei{qw(opt env)};
	my @qform = (q => $lei->{mset_opt}->{qstr}, x => 'm');
	push(@qform, t => 1) if $opt->{thread};
	my @cmd = ($self->{curl}, qw(-sSf -d), '');
	my $verbose = $opt->{verbose};
	my $reap;
	my $cerr = File::Temp->new(TEMPLATE => 'curl.err-XXXX', TMPDIR => 1);
	fcntl($cerr, F_SETFL, O_APPEND|O_RDWR) or warn "set O_APPEND: $!";
	my $rdr = { 2 => $cerr };
	my $coff = 0;
	if ($verbose) {
		# spawn a process to force line-buffering, otherwise curl
		# will write 1 character at-a-time and parallel outputs
		# mmmaaayyy llloookkk llliiikkkeee ttthhhiiisss
		push @cmd, '-v';
		my $o = { 1 => $lei->{2}, 2 => $lei->{2} };
		my $pid = spawn(['tail', '-f', $cerr->filename], undef, $o);
		$reap = PublicInbox::OnDestroy->new(\&kill_reap, $pid);
	}
	for my $o ($lei->curl_opt) {
		$o =~ s/\|[a-z0-9]\b//i; # remove single char short option
		if ($o =~ s/=[is]@\z//) {
			my $ary = $opt->{$o} or next;
			push @cmd, map { ("--$o", $_) } @$ary;
		} elsif ($o =~ s/=[is]\z//) {
			my $val = $opt->{$o} // next;
			push @cmd, "--$o", $val;
		} elsif ($opt->{$o}) {
			push @cmd, "--$o";
		}
	}
	$opt->{torsocks} = 'false' if $opt->{'no-torsocks'};
	my $tor = $opt->{torsocks} //= 'auto';
	my $each_smsg = $lei->{ovv}->ovv_each_smsg_cb($lei);
	for my $uri (@$uris) {
		$lei->{-current_url} = $uri->as_string;
		$lei->{-nr_remote_eml} = 0;
		$uri->query_form(@qform);
		my $cmd = [ @cmd, $uri->as_string ];
		if ($tor eq 'auto' && substr($uri->host, -6) eq '.onion' &&
				(($env->{LD_PRELOAD}//'') !~ /torsocks/)) {
			unshift @$cmd, which('torsocks');
		} elsif (PublicInbox::Config::git_bool($tor)) {
			unshift @$cmd, which('torsocks');
		}

		# continue anyways if torsocks is missing; a proxy may be
		# specified via CLI, curlrc, environment variable, or even
		# firewall rule
		shift(@$cmd) if !$cmd->[0];

		$lei->err("# @$cmd") if $verbose;
		$? = 0;
		my $fh = popen_rd($cmd, $env, $rdr);
		$fh = IO::Uncompress::Gunzip->new($fh);
		eval {
			PublicInbox::MboxReader->mboxrd($fh, \&each_eml, $self,
							$lei, $each_smsg);
		};
		return $lei->fail("E: @$cmd: $@") if $@;
		if ($? == 0) {
			my $nr = $lei->{-nr_remote_eml};
			pkt_do($lei->{pkt_op}, 'mset_progress',
				$lei->{-current_url}, $nr, $nr);
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
	my ($lei) = @_;
	my $has_l2m = exists $lei->{l2m};
	for my $f (qw(lxs l2m)) {
		my $wq = delete $lei->{$f} or next;
		$wq->wq_wait_old($lei);
	}
	$lei->{ovv}->ovv_end($lei);
	if ($has_l2m) { # close() calls LeiToMail reap_compress
		if (my $out = delete $lei->{old_1}) {
			if (my $mbout = $lei->{1}) {
				close($mbout) or return $lei->fail(<<"");
Error closing $lei->{ovv}->{dst}: $!

			}
			$lei->{1} = $out;
		}
		$lei->start_mua;
	}
	$lei->{opt}->{quiet} or
		$lei->err('# ', $lei->{-mset_total} // 0, " matches");
	$lei->dclose;
}

sub mset_progress { # called via pkt_op/pkt_do from workers
	my ($lei, $pargs) = @_;
	my ($desc, $mset_size, $mset_total_est) = @$pargs;
	return if $lei->{opt}->{quiet};
	$lei->{-mset_total} += $mset_size;
	$lei->err("# $desc $mset_size/$mset_total_est");
}

sub do_post_augment {
	my ($lei, $zpipe, $au_done) = @_;
	my $l2m = $lei->{l2m} or die 'BUG: no {l2m}';
	eval { $l2m->post_augment($lei, $zpipe) };
	if (my $err = $@) {
		if (my $lxs = delete $lei->{lxs}) {
			$lxs->wq_kill;
			$lxs->wq_close;
		}
		$lei->fail("$err");
	}
	close $au_done; # triggers wait_startq
}

my $MAX_PER_HOST = 4;
sub MAX_PER_HOST { $MAX_PER_HOST }

sub concurrency {
	my ($self, $opt) = @_;
	my $nl = $opt->{thread} ? locals($self) : 1;
	my $nr = remotes($self);
	$nr = $MAX_PER_HOST if $nr > $MAX_PER_HOST;
	$nl + $nr;
}

sub start_query { # always runs in main (lei-daemon) process
	my ($self, $io, $lei) = @_;
	if ($lei->{opt}->{thread}) {
		for my $ibxish (locals($self)) {
			$self->wq_do('query_thread_mset', $io, $lei, $ibxish);
		}
	} elsif (locals($self)) {
		$self->wq_do('query_mset', $io, $lei);
	}
	my $i = 0;
	my $q = [];
	for my $uri (remotes($self)) {
		push @{$q->[$i++ % $MAX_PER_HOST]}, $uri;
	}
	for my $uris (@$q) {
		$self->wq_do('query_remote_mboxrd', $io, $lei, $uris);
	}
	@$io = ();
}

sub query_prepare { # called by wq_do
	my ($self, $lei) = @_;
	local $0 = "$0 query_prepare";
	$lei->atfork_child_wq($self);
	delete $lei->{l2m}->{-wq_s1};
	eval { $lei->{l2m}->do_augment($lei) };
	$lei->fail($@) if $@;
	pkt_do($lei->{pkt_op}, '.') == 1 or die "do_post_augment trigger: $!"
}

sub fail_handler ($;$$) {
	my ($lei, $code, $io) = @_;
	if (my $lxs = delete $lei->{lxs}) {
		$lxs->wq_wait_old($lei) if $lxs->wq_kill_old; # lei-daemon
	}
	close($io) if $io; # needed to avoid warnings on SIGPIPE
	$lei->x_it($code // (1 >> 8));
}

sub sigpipe_handler { # handles SIGPIPE from l2m/lxs workers
	fail_handler($_[0], 13, delete $_[0]->{1});
}

sub do_query {
	my ($self, $lei) = @_;
	$lei->{1}->autoflush(1);
	my ($au_done, $zpipe);
	my $l2m = $lei->{l2m};
	if ($l2m) {
		pipe($lei->{startq}, $au_done) or die "pipe: $!";
		# 1031: F_SETPIPE_SZ
		fcntl($lei->{startq}, 1031, 4096) if $^O eq 'linux';
		$zpipe = $l2m->pre_augment($lei);
	}
	my $in_loop = exists $lei->{sock};
	my $ops = {
		'|' => [ \&sigpipe_handler, $lei ],
		'!' => [ \&fail_handler, $lei ],
		'.' => [ \&do_post_augment, $lei, $zpipe, $au_done ],
		'' => [ \&query_done, $lei ],
		'mset_progress' => [ \&mset_progress, $lei ],
	};
	(my $op, $lei->{pkt_op}) = PublicInbox::PktOp->pair($ops, $in_loop);
	my ($lei_ipc, @io) = $lei->atfork_parent_wq($self);
	delete($lei->{pkt_op});

	$lei->event_step_init; # wait for shutdowns
	if ($l2m) {
		$self->wq_do('query_prepare', \@io, $lei_ipc);
		$io[1] = $zpipe->[1] if $zpipe;
	}
	start_query($self, \@io, $lei_ipc);
	$self->wq_close(1);
	unless ($in_loop) {
		# for the $lei_ipc->atfork_child_wq PIPE handler:
		while ($op->{sock}) { $op->event_step }
	}
}

sub add_uri {
	my ($self, $uri) = @_;
	if (my $curl = $self->{curl} //= which('curl') // 0) {
		require PublicInbox::MboxReader;
		require IO::Uncompress::Gunzip;
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
