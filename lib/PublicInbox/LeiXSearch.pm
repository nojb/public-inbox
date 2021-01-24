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
use PublicInbox::Search qw(xap_terms);
use PublicInbox::Spawn qw(popen_rd);

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
	local $0 = "$0 query_thread_mset";
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
	my ($self, $lei) = @_;
	local $0 = "$0 query_mset";
	my $startq = delete $self->{5};
	my %sig = $lei->atfork_child_wq($self);
	local @SIG{keys %sig} = values %sig;
	my $mo = { %{$lei->{mset_opt}} };
	my $mset;
	for my $loc (locals($self)) {
		attach_external($self, $loc);
	}
	my $each_smsg = $lei->{ovv}->ovv_each_smsg_cb($lei, $self);
	my $dedupe = $lei->{dedupe} // die 'BUG: {dedupe} missing';
	$dedupe->prepare_dedupe;
	do {
		$mset = $self->mset($mo->{qstr}, $mo);
		for my $mitem ($mset->items) {
			my $smsg = smsg_for($self, $mitem) or next;
			wait_startq($startq) if $startq;
			next if $dedupe->is_smsg_dup($smsg);
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
	$smsg->{$_} //= '' for qw(from to cc ds subject references mid);
	delete @$smsg{qw(From Subject -ds -ts)};
	if (my $startq = delete($self->{5})) { wait_startq($startq) }
	return if !$lei->{l2m} && $lei->{dedupe}->is_smsg_dup($smsg);
	$each_smsg->($smsg, undef, $eml);
}

sub query_remote_mboxrd {
	my ($self, $lei, $uris) = @_;
	local $0 = "$0 query_remote_mboxrd";
	my %sig = $lei->atfork_child_wq($self); # keep $self->{5} startq
	local @SIG{keys %sig} = values %sig;
	my ($opt, $env) = @$lei{qw(opt env)};
	my @qform = (q => $lei->{mset_opt}->{qstr}, x => 'm');
	push(@qform, t => 1) if $opt->{thread};
	my $dedupe = $lei->{dedupe} // die 'BUG: {dedupe} missing';
	$dedupe->prepare_dedupe;
	my @cmd = qw(curl -XPOST -sSf);
	my $verbose = $opt->{verbose};
	push @cmd, '-v' if $verbose;
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
	for my $uri (@$uris) {
		$uri->query_form(@qform);
		my $each_smsg = $lei->{ovv}->ovv_each_smsg_cb($lei, $uri);
		my $cmd = [ @cmd, $uri->as_string ];
		if ($tor eq 'auto' && substr($uri->host, -6) eq '.onion' &&
				(($env->{LD_PRELOAD}//'') !~ /torsocks/)) {
			unshift @$cmd, 'torsocks';
		} elsif (PublicInbox::Config::git_bool($tor)) {
			unshift @$cmd, 'torsocks';
		}
		$lei->err("# @$cmd") if $verbose;
		$? = 0;
		my $fh = popen_rd($cmd, $env, { 2 => $lei->{2} });
		$fh = IO::Uncompress::Gunzip->new($fh);
		eval {
			PublicInbox::MboxReader->mboxrd($fh, \&each_eml, $self,
							$lei, $each_smsg);
		};
		return $lei->fail("E: @$cmd: $@") if $@;
		if (($? >> 8) == 22) { # HTTP 404 from curl(1)
			$uri->query_form(q => $lei->{mset_opt}->{qstr});
			$lei->err('# no results from '.$uri->as_string);
		} elsif ($?) {
			$uri->query_form(q => $lei->{mset_opt}->{qstr});
			$lei->err('E: '.$uri->as_string);
			$lei->child_error($?);
		}
	}
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
		$wq->wq_wait_old;
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
	$lei->dclose;
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
	my %sig = $lei->atfork_child_wq($self);
	-p $lei->{0} or die "BUG: \$done pipe expected";
	local @SIG{keys %sig} = values %sig;
	eval { $lei->{l2m}->do_augment($lei) };
	$lei->fail($@) if $@;
	syswrite($lei->{0}, '.') == 1 or die "do_post_augment trigger: $!";
}

sub sigpipe_handler { # handles SIGPIPE from l2m/lxs workers
	my ($lei) = @_;
	my $lxs = delete $lei->{lxs};
	if ($lxs && $lxs->wq_kill_old) {
		kill 'PIPE', $$;
		$lxs->wq_wait_old;
	}
	close(delete $lei->{1}) if $lei->{1};
}

sub do_query {
	my ($self, $lei_orig) = @_;
	my ($lei, @io) = $lei_orig->atfork_parent_wq($self);
	$io[0] = undef;
	pipe(my $done, $io[0]) or die "pipe $!";
	$lei_orig->{1}->autoflush(1);

	$lei_orig->event_step_init; # wait for shutdowns
	my $done_op = {
		'' => [ \&query_done, $lei_orig ],
		'!' => [ \&sigpipe_handler, $lei_orig ]
	};
	my $in_loop = exists $lei_orig->{sock};
	$done = PublicInbox::OpPipe->new($done, $done_op, $in_loop);
	my $l2m = $lei->{l2m};
	if ($l2m) {
		# may redirect $lei->{1} for mbox
		my $zpipe = $l2m->pre_augment($lei_orig);
		$io[1] = $lei_orig->{1};
		pipe(my ($startq, $au_done)) or die "pipe: $!";
		$done_op->{'.'} = [ \&do_post_augment, $lei_orig,
					$zpipe, $au_done ];
		local $io[4] = *STDERR{GLOB}; # don't send l2m->{-wq_s1}
		die "BUG: unexpected \$io[5]: $io[5]" if $io[5];
		$self->wq_do('query_prepare', \@io, $lei);
		fcntl($startq, 1031, 4096) if $^O eq 'linux'; # F_SETPIPE_SZ
		$io[5] = $startq;
		$io[1] = $zpipe->[1] if $zpipe;
	}
	start_query($self, \@io, $lei);
	$self->wq_close(1);
	unless ($in_loop) {
		# for the $lei->atfork_child_wq PIPE handler:
		while ($done->{sock}) { $done->event_step }
	}
}

sub ipc_atfork_prepare {
	my ($self) = @_;
	if (exists $self->{remotes}) {
		require PublicInbox::MboxReader;
		require IO::Uncompress::Gunzip;
	}
	# FDS: (0: done_wr, 1: stdout|mbox, 2: stderr,
	#       3: sock, 4: $l2m->{-wq_s1}, 5: $startq)
	$self->SUPER::ipc_atfork_prepare; # PublicInbox::IPC
}

sub prepare_external {
	my ($self, $loc, $boost) = @_; # n.b. already ordered by boost
	if (ref $loc) { # already a URI, or PublicInbox::Inbox-like object
		return push(@{$self->{remotes}}, $loc) if $loc->can('scheme');
	} elsif ($loc =~ m!\Ahttps?://!) {
		require URI;
		return push(@{$self->{remotes}}, URI->new($loc));
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
