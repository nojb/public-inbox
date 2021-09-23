# Copyright (C) 2018-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
package PublicInbox::Xapcmd;
use strict;
use PublicInbox::Spawn qw(which popen_rd nodatacow_dir);
use PublicInbox::Admin qw(setup_signals);
use PublicInbox::Over;
use PublicInbox::SearchIdx;
use File::Temp 0.19 (); # ->newdir
use File::Path qw(remove_tree);
use POSIX qw(WNOHANG _exit);

# support testing with dev versions of Xapian which installs
# commands with a version number suffix (e.g. "xapian-compact-1.5")
our $XAPIAN_COMPACT = $ENV{XAPIAN_COMPACT} || 'xapian-compact';
our @COMPACT_OPT = qw(jobs|j=i quiet|q blocksize|b=s no-full|n fuller|F);

sub commit_changes ($$$$) {
	my ($ibx, $im, $tmp, $opt) = @_;
	my $reshard = $opt->{reshard};

	$SIG{INT} or die 'BUG: $SIG{INT} not handled';
	my (@old_shard, $over_chg);

	# Sort shards highest-to-lowest, since ->xdb_shards_flat
	# determines the number of shards to load based on the max;
	# and we'd rather xdb_shards_flat to momentarily fail rather
	# than load out-of-date shards
	my @order = sort {
		my ($x) = ($a =~ m!/([0-9]+)/*\z!);
		my ($y) = ($b =~ m!/([0-9]+)/*\z!);
		($y // -1) <=> ($x // -1) # we may have non-shards
	} keys %$tmp;

	my ($dname) = ($order[0] =~ m!(.*/)[^/]+/*\z!);
	my $mode = (stat($dname))[2];
	for my $old (@order) {
		next if $old eq ''; # no invalid paths
		my $newdir = $tmp->{$old};
		my $have_old = -e $old;
		if (!$have_old && !defined($opt->{reshard})) {
			die "failed to stat($old): $!";
		}

		my $new = $newdir->dirname if defined($newdir);
		my $over = "$old/over.sqlite3";
		if (-f $over) { # only for v1, v2 over is untouched
			defined $new or die "BUG: $over exists when culling v2";
			$over = PublicInbox::Over->new($over);
			my $tmp_over = "$new/over.sqlite3";
			$over->dbh->sqlite_backup_to_file($tmp_over);
			$over = undef;
			$over_chg = 1;
		}

		if (!defined($new)) { # culled shard
			push @old_shard, $old;
			next;
		}

		chmod($mode & 07777, $new) or die "chmod($new): $!\n";
		if ($have_old) {
			rename($old, "$new/old") or
					die "rename $old => $new/old: $!\n";
		}
		rename($new, $old) or die "rename $new => $old: $!\n";
		push @old_shard, "$old/old" if $have_old;
	}

	# trigger ->check_inodes in read-only daemons
	syswrite($im->{lockfh}, '.') if $over_chg && $im;

	remove_tree(@old_shard);
	$tmp = undef;
	if (!$opt->{-coarse_lock}) {
		$opt->{-skip_lock} = 1;
		$im //= $ibx if $ibx->can('eidx_sync');
		if ($im->can('count_shards')) { # v2w or eidx
			my $pr = $opt->{-progress};
			my $n = $im->count_shards;
			if (defined $reshard && $n != $reshard) {
				die
"BUG: counted $n shards after resharding to $reshard";
			}
			my $prev = $im->{shards};
			if ($pr && $prev != $n) {
				$pr->("shard count changed: $prev => $n\n");
				$im->{shards} = $n;
			}
		}
		my $env = $opt->{-idx_env};
		local %ENV = (%ENV, %$env) if $env;
		if ($ibx->can('eidx_sync')) {
			$ibx->eidx_sync($opt);
		} else {
			PublicInbox::Admin::index_inbox($ibx, $im, $opt);
		}
	}
}

sub cb_spawn {
	my ($cb, $args, $opt) = @_; # $cb = cpdb() or compact()
	my $seed = rand(0xffffffff);
	my $pid = fork // die "fork: $!";
	return $pid if $pid > 0;
	srand($seed);
	$SIG{__DIE__} = sub { warn @_; _exit(1) }; # don't jump up stack
	$cb->($args, $opt);
	_exit(0);
}

sub runnable_or_die ($) {
	my ($exe) = @_;
	which($exe) or die "$exe not found in PATH\n";
}

sub prepare_reindex ($$) {
	my ($ibx, $opt) = @_;
	if ($ibx->can('eidx_sync')) { # no prep needed for ExtSearchIdx
	} elsif ($ibx->version == 1) {
		my $dir = $ibx->search->xdir(1);
		my $xdb = $PublicInbox::Search::X{Database}->new($dir);
		if (my $lc = $xdb->get_metadata('last_commit')) {
			$opt->{reindex}->{from} = $lc;
		}
	} else { # v2
		my $max = $ibx->max_git_epoch // return;
		my $from = $opt->{reindex}->{from};
		my $mm = $ibx->mm;
		my $v = PublicInbox::Search::SCHEMA_VERSION();
		foreach my $i (0..$max) {
			$from->[$i] = $mm->last_commit_xap($v, $i);
		}
	}
}

sub same_fs_or_die ($$) {
	my ($x, $y) = @_;
	return if ((stat($x))[0] == (stat($y))[0]); # 0 - st_dev
	die "$x and $y reside on different filesystems\n";
}

sub kill_pids {
	my ($sig, $pids) = @_;
	kill($sig, keys %$pids); # pids may be empty
}

sub process_queue {
	my ($queue, $cb, $opt) = @_;
	my $max = $opt->{jobs} // scalar(@$queue);
	if ($max <= 1) {
		while (defined(my $args = shift @$queue)) {
			$cb->($args, $opt);
		}
		return;
	}

	# run in parallel:
	my %pids;
	local @SIG{keys %SIG} = values %SIG;
	setup_signals(\&kill_pids, \%pids);
	while (@$queue) {
		while (scalar(keys(%pids)) < $max && scalar(@$queue)) {
			my $args = shift @$queue;
			$pids{cb_spawn($cb, $args, $opt)} = $args;
		}

		my $flags = 0;
		while (scalar keys %pids) {
			my $pid = waitpid(-1, $flags) or last;
			last if $pid < 0;
			my $args = delete $pids{$pid};
			if ($args) {
				die join(' ', @$args)." failed: $?\n" if $?;
			} else {
				warn "unknown PID($pid) reaped: $?\n";
			}
			$flags = WNOHANG if scalar(@$queue);
		}
	}
}

sub prepare_run {
	my ($ibx, $opt) = @_;
	my $tmp = {}; # old shard dir => File::Temp->newdir object or undef
	my @queue; # ([old//src,newdir]) - list of args for cpdb() or compact()
	my ($old, $misc_ok);
	if ($ibx->can('eidx_sync')) {
		$misc_ok = 1;
		$old = $ibx->xdir(1);
	} elsif (my $srch = $ibx->search) {
		$old = $srch->xdir(1);
	}
	if (defined $old) {
		-d $old or die "$old does not exist\n";
	}
	my $reshard = $opt->{reshard};
	if (defined $reshard && $reshard <= 0) {
		die "--reshard must be a positive number\n";
	}

	# we want temporary directories to be as deep as possible,
	# so v2 shards can keep "xap$SCHEMA_VERSION" on a separate FS.
	if (defined($old) && $ibx->can('version') && $ibx->version == 1) {
		if (defined $reshard) {
			warn
"--reshard=$reshard ignored for v1 $ibx->{inboxdir}\n";
		}
		my ($dir) = ($old =~ m!(.*?/)[^/]+/*\z!);
		same_fs_or_die($dir, $old);
		my $v = PublicInbox::Search::SCHEMA_VERSION();
		my $wip = File::Temp->newdir("xapian$v-XXXX", DIR => $dir);
		$tmp->{$old} = $wip;
		nodatacow_dir($wip->dirname);
		push @queue, [ $old, $wip ];
	} elsif (defined $old) {
		opendir my $dh, $old or die "Failed to opendir $old: $!\n";
		my @old_shards;
		while (defined(my $dn = readdir($dh))) {
			if ($dn =~ /\A[0-9]+\z/) {
				push @old_shards, $dn;
			} elsif ($dn eq '.' || $dn eq '..') {
			} elsif ($dn =~ /\Aover\.sqlite3/) {
			} elsif ($dn eq 'misc' && $misc_ok) {
			} else {
				warn "W: skipping unknown dir: $old/$dn\n"
			}
		}
		die "No Xapian shards found in $old\n" unless @old_shards;

		my ($src, $max_shard);
		if (!defined($reshard) || $reshard == scalar(@old_shards)) {
			# 1:1 copy
			$max_shard = scalar(@old_shards) - 1;
		} else {
			# M:N copy
			$max_shard = $reshard - 1;
			$src = [ map { "$old/$_" } @old_shards ];
		}
		foreach my $dn (0..$max_shard) {
			my $wip = File::Temp->newdir("$dn-XXXX", DIR => $old);
			same_fs_or_die($old, $wip->dirname);
			my $cur = "$old/$dn";
			push @queue, [ $src // $cur , $wip ];
			nodatacow_dir($wip->dirname);
			$tmp->{$cur} = $wip;
		}
		# mark old shards to be unlinked
		if ($src) {
			$tmp->{$_} ||= undef for @$src;
		}
	}
	($tmp, \@queue);
}

sub check_compact () { runnable_or_die($XAPIAN_COMPACT) }

sub _run { # with_umask callback
	my ($ibx, $cb, $opt) = @_;
	my $im = $ibx->can('importer') ? $ibx->importer(0) : undef;
	($im // $ibx)->lock_acquire;
	my ($tmp, $queue) = prepare_run($ibx, $opt);

	# fine-grained locking if we prepare for reindex
	if (!$opt->{-coarse_lock}) {
		prepare_reindex($ibx, $opt);
		($im // $ibx)->lock_release;
	}

	$ibx->cleanup if $ibx->can('cleanup');
	process_queue($queue, $cb, $opt);
	($im // $ibx)->lock_acquire if !$opt->{-coarse_lock};
	commit_changes($ibx, $im, $tmp, $opt);
}

sub run {
	my ($ibx, $task, $opt) = @_; # task = 'cpdb' or 'compact'
	my $cb = \&$task;
	PublicInbox::Admin::progress_prepare($opt ||= {});
	my $dir;
	for my $fld (qw(inboxdir topdir)) {
		my $d = $ibx->{$fld} // next;
		-d $d or die "$fld=$d does not exist\n";
		$dir = $d;
		last;
	}
	check_compact() if $opt->{compact} && $ibx->search;

	if (!$ibx->can('eidx_sync') && !$opt->{-coarse_lock}) {
		# per-epoch ranges for v2
		# v1:{ from => $OID }, v2:{ from => [ $OID, $OID, $OID ] } }
		$opt->{reindex} = { from => $ibx->version == 1 ? '' : [] };
		PublicInbox::SearchIdx::load_xapian_writable();
	}

	local @SIG{keys %SIG} = values %SIG;
	setup_signals();
	$ibx->with_umask(\&_run, $ibx, $cb, $opt);
}

sub cpdb_retryable ($$) {
	my ($src, $pfx) = @_;
	if (ref($@) =~ /\bDatabaseModifiedError\b/) {
		warn "$pfx Xapian DB modified, reopening and retrying\n";
		$src->reopen;
		return 1;
	}
	if ($@) {
		warn "$pfx E: ", ref($@), "\n";
		die;
	}
	0;
}

sub progress_pfx ($) {
	my ($wip) = @_; # tempdir v2: ([0-9])+-XXXX
	my @p = split('/', $wip);

	# return "xap15/0" for v2, or "xapian15" for v1:
	($p[-1] =~ /\A([0-9]+)/) ? "$p[-2]/$1" : $p[-1];
}

sub kill_compact { # setup_signals callback
	my ($sig, $pidref) = @_;
	kill($sig, $$pidref) if defined($$pidref);
}

# xapian-compact wrapper
sub compact ($$) { # cb_spawn callback
	my ($args, $opt) = @_;
	my ($src, $newdir) = @$args;
	my $dst = ref($newdir) ? $newdir->dirname : $newdir;
	my $pfx = $opt->{-progress_pfx} ||= progress_pfx($src);
	my $pr = $opt->{-progress};
	my $rdr = {};

	foreach my $fd (0..2) {
		defined(my $dfd = $opt->{$fd}) or next;
		$rdr->{$fd} = $dfd;
	}

	# we rely on --no-renumber to keep docids synched to NNTP
	my $cmd = [ $XAPIAN_COMPACT, '--no-renumber' ];
	for my $sw (qw(no-full fuller)) {
		push @$cmd, "--$sw" if $opt->{$sw};
	}
	for my $sw (qw(blocksize)) {
		defined(my $v = $opt->{$sw}) or next;
		push @$cmd, "--$sw", $v;
	}
	$pr->("$pfx `".join(' ', @$cmd)."'\n") if $pr;
	push @$cmd, $src, $dst;
	my ($rd, $pid);
	local @SIG{keys %SIG} = values %SIG;
	setup_signals(\&kill_compact, \$pid);
	($rd, $pid) = popen_rd($cmd, undef, $rdr);
	while (<$rd>) {
		if ($pr) {
			s/\r/\r$pfx /g;
			$pr->("$pfx $_");
		}
	}
	waitpid($pid, 0);
	die "@$cmd failed: \$?=$?\n" if $?;
}

sub cpdb_loop ($$$;$$) {
	my ($src, $dst, $pr_data, $cur_shard, $reshard) = @_;
	my ($pr, $fmt, $nr, $pfx);
	if ($pr_data) {
		$pr = $pr_data->{pr};
		$fmt = $pr_data->{fmt};
		$nr = \($pr_data->{nr});
		$pfx = $pr_data->{pfx};
	}

	my ($it, $end);
	do {
		eval {
			$it = $src->postlist_begin('');
			$end = $src->postlist_end('');
		};
	} while (cpdb_retryable($src, $pfx));

	do {
		eval {
			for (; $it != $end; $it++) {
				my $docid = $it->get_docid;
				if (defined $reshard) {
					my $dst_shard = $docid % $reshard;
					next if $dst_shard != $cur_shard;
				}
				my $doc = $src->get_document($docid);
				$dst->replace_document($docid, $doc);
				if ($pr_data && !(++$$nr  & 1023)) {
					$pr->(sprintf($fmt, $$nr));
				}
			}

			# unlike copydatabase(1), we don't copy spelling
			# and synonym data (or other user metadata) since
			# the Perl APIs don't expose iterators for them
			# (and public-inbox does not use those features)
		};
	} while (cpdb_retryable($src, $pfx));
}

# Like copydatabase(1), this is horribly slow; and it doesn't seem due
# to the overhead of Perl.
sub cpdb ($$) { # cb_spawn callback
	my ($args, $opt) = @_;
	my ($old, $newdir) = @$args;
	my $new = $newdir->dirname;
	my ($src, $cur_shard);
	my $reshard;
	PublicInbox::SearchIdx::load_xapian_writable();
	my $XapianDatabase = $PublicInbox::Search::X{Database};
	if (ref($old) eq 'ARRAY') {
		($cur_shard) = ($new =~ m!(?:xap|ei)[0-9]+/([0-9]+)\b!);
		defined $cur_shard or
			die "BUG: could not extract shard # from $new";
		$reshard = $opt->{reshard};
		defined $reshard or die 'BUG: got array src w/o --reshard';

		# resharding, M:N copy means have full read access
		foreach (@$old) {
			if ($src) {
				my $sub = $XapianDatabase->new($_);
				$src->add_database($sub);
			} else {
				$src = $XapianDatabase->new($_);
			}
		}
	} else {
		$src = $XapianDatabase->new($old);
	}

	my ($tmp, $ft);
	local @SIG{keys %SIG} = values %SIG;
	if ($opt->{compact}) {
		my ($dir) = ($new =~ m!(.*?/)[^/]+/*\z!);
		same_fs_or_die($dir, $new);
		$ft = File::Temp->newdir("$new.compact-XXXX", DIR => $dir);
		setup_signals();
		$tmp = $ft->dirname;
		nodatacow_dir($tmp);
	} else {
		$tmp = $new;
	}

	# like copydatabase(1), be sure we don't overwrite anything in case
	# of other bugs:
	my $flag = eval($PublicInbox::Search::Xap.'::DB_CREATE()');
	die if $@;
	my $XapianWritableDatabase = $PublicInbox::Search::X{WritableDatabase};
	$flag |= $PublicInbox::SearchIdx::DB_NO_SYNC if !$opt->{fsync};
	my $dst = $XapianWritableDatabase->new($tmp, $flag);
	my $pr = $opt->{-progress};
	my $pfx = $opt->{-progress_pfx} = progress_pfx($new);
	my $pr_data = { pr => $pr, pfx => $pfx, nr => 0 } if $pr;

	do {
		eval {
			# update the only metadata key for v1:
			my $lc = $src->get_metadata('last_commit');
			$dst->set_metadata('last_commit', $lc) if $lc;

			# only the first xapian shard (0) gets 'indexlevel'
			if ($new =~ m!(?:xapian[0-9]+|xap[0-9]+/0)\b!) {
				my $l = $src->get_metadata('indexlevel');
				if ($l eq 'medium') {
					$dst->set_metadata('indexlevel', $l);
				}
			}
			if ($pr_data) {
				my $tot = $src->get_doccount;

				# we can only estimate when resharding,
				# because removed spam causes slight imbalance
				my $est = '';
				if (defined $cur_shard && $reshard > 1) {
					$tot = int($tot/$reshard);
					$est = 'around ';
				}
				my $fmt = "$pfx % ".length($tot)."u/$tot\n";
				$pr->("$pfx copying $est$tot documents\n");
				$pr_data->{fmt} = $fmt;
				$pr_data->{total} = $tot;
			}
		};
	} while (cpdb_retryable($src, $pfx));

	if (defined $reshard) {
		# we rely on document IDs matching NNTP article number,
		# so we can't have the Xapian sharding DB support rewriting
		# document IDs.  Thus we iterate through each shard
		# individually.
		$src = undef;
		foreach (@$old) {
			my $old = $XapianDatabase->new($_);
			cpdb_loop($old, $dst, $pr_data, $cur_shard, $reshard);
		}
	} else {
		cpdb_loop($src, $dst, $pr_data);
	}

	$pr->(sprintf($pr_data->{fmt}, $pr_data->{nr})) if $pr;
	return unless $opt->{compact};

	$src = $dst = undef; # flushes and closes

	# this is probably the best place to do xapian-compact
	# since $dst isn't readable by HTTP or NNTP clients, yet:
	compact([ $tmp, $new ], $opt);
	remove_tree($tmp) or die "failed to remove $tmp: $!\n";
}

1;
