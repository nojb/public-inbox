# Copyright (C) 2018-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
package PublicInbox::Xapcmd;
use strict;
use warnings;
use PublicInbox::Spawn qw(which spawn);
use PublicInbox::Over;
use PublicInbox::Search;
use File::Temp qw(tempdir);
use File::Path qw(remove_tree);
use File::Basename qw(dirname);

# support testing with dev versions of Xapian which installs
# commands with a version number suffix (e.g. "xapian-compact-1.5")
our $XAPIAN_COMPACT = $ENV{XAPIAN_COMPACT} || 'xapian-compact';
our @COMPACT_OPT = qw(jobs|j=i quiet|q blocksize|b=s no-full|n fuller|F);

sub commit_changes ($$$) {
	my ($ibx, $tmp, $opt) = @_;
	my $new_parts = $opt->{reshard};
	my $reindex = $opt->{reindex};
	my $im = $ibx->importer(0);
	$im->lock_acquire if !$opt->{-coarse_lock};

	$SIG{INT} or die 'BUG: $SIG{INT} not handled';
	my @old_part;

	while (my ($old, $new) = each %$tmp) {
		my @st = stat($old);
		if (!@st && !defined($opt->{reshard})) {
			die "failed to stat($old): $!";
		}

		my $over = "$old/over.sqlite3";
		if (-f $over) { # only for v1, v2 over is untouched
			defined $new or die "BUG: $over exists when culling v2";
			$over = PublicInbox::Over->new($over);
			my $tmp_over = "$new/over.sqlite3";
			$over->connect->sqlite_backup_to_file($tmp_over);
			$over = undef;
		}

		if (!defined($new)) { # culled partition
			push @old_part, $old;
			next;
		}

		if (@st) {
			chmod($st[2] & 07777, $new) or die "chmod $old: $!\n";
			rename($old, "$new/old") or
					die "rename $old => $new/old: $!\n";
		}
		# Xtmpdir->DESTROY won't remove $new after this:
		rename($new, $old) or die "rename $new => $old: $!\n";
		if (@st) {
			my $prev = "$old/old";
			remove_tree($prev) or
				die "failed to remove $prev: $!\n";
		}
	}
	remove_tree(@old_part);
	$tmp->done;
	if (!$opt->{-coarse_lock}) {
		$opt->{-skip_lock} = 1;

		if ($im->can('count_shards')) {
			my $pr = $opt->{-progress};
			my $n = $im->count_shards;
			if (defined $new_parts && $n != $new_parts) {
				die
"BUG: counted $n shards after resharding to $new_parts";
			}
			my $prev = $im->{shards};
			if ($pr && $prev != $n) {
				$pr->("shard count changed: $prev => $n\n");
				$im->{shards} = $n;
			}
		}

		PublicInbox::Admin::index_inbox($ibx, $opt);
		# implicit lock_release
	} else {
		$im->lock_release;
	}
}

sub cb_spawn {
	my ($cb, $args, $opt) = @_; # $cb = cpdb() or compact()
	defined(my $pid = fork) or die "fork: $!";
	return $pid if $pid > 0;
	$cb->($args, $opt);
	exit 0;
}

sub runnable_or_die ($) {
	my ($exe) = @_;
	which($exe) or die "$exe not found in PATH\n";
}

sub prepare_reindex ($$) {
	my ($ibx, $reindex) = @_;
	if ($ibx->{version} == 1) {
		my $dir = $ibx->search->xdir(1);
		my $xdb = Search::Xapian::Database->new($dir);
		if (my $lc = $xdb->get_metadata('last_commit')) {
			$reindex->{from} = $lc;
		}
	} else { # v2
		my $v2w = $ibx->importer(0);
		my $max;
		$v2w->git_dir_latest(\$max) or return;
		my $from = $reindex->{from};
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

sub process_queue {
	my ($queue, $cb, $max, $opt) = @_;
	if ($max <= 1) {
		while (defined(my $args = shift @$queue)) {
			$cb->($args, $opt);
		}
		return;
	}

	# run in parallel:
	my %pids;
	while (@$queue) {
		while (scalar(keys(%pids)) < $max && scalar(@$queue)) {
			my $args = shift @$queue;
			$pids{cb_spawn($cb, $args, $opt)} = $args;
		}

		while (scalar keys %pids) {
			my $pid = waitpid(-1, 0);
			my $args = delete $pids{$pid};
			die join(' ', @$args)." failed: $?\n" if $?;
		}
	}
}

sub run {
	my ($ibx, $task, $opt) = @_; # task = 'cpdb' or 'compact'
	my $cb = \&${\"PublicInbox::Xapcmd::$task"};
	PublicInbox::Admin::progress_prepare($opt ||= {});
	my $dir = $ibx->{mainrepo} or die "no mainrepo in inbox\n";
	runnable_or_die($XAPIAN_COMPACT) if $opt->{compact};
	my $reindex; # v1:{ from => $x40 }, v2:{ from => [ $x40, $x40, .. ] } }
	my $from; # per-epoch ranges

	if (!$opt->{-coarse_lock}) {
		$reindex = $opt->{reindex} = {};
		$from = $reindex->{from} = [];
		require Search::Xapian::WritableDatabase;
	}

	$ibx->umask_prepare;
	my $old = $ibx->search->xdir(1);
	-d $old or die "$old does not exist\n";

	my $tmp = PublicInbox::Xtmpdirs->new;
	my $v = $ibx->{version} ||= 1;
	my @q;
	my $new_parts = $opt->{reshard};
	if (defined $new_parts && $new_parts <= 0) {
		die "--reshard must be a positive number\n";
	}

	# we want temporary directories to be as deep as possible,
	# so v2 shards can keep "xap$SCHEMA_VERSION" on a separate FS.
	if ($v == 1) {
		if (defined $new_parts) {
			warn
"--reshard=$new_parts ignored for v1 $ibx->{mainrepo}\n";
		}
		my $old_parent = dirname($old);
		same_fs_or_die($old_parent, $old);
		my $v = PublicInbox::Search::SCHEMA_VERSION();
		my $wip = tempdir("xapian$v-XXXXXXXX", DIR => $old_parent);
		$tmp->{$old} = $wip;
		push @q, [ $old, $wip ];
	} else {
		opendir my $dh, $old or die "Failed to opendir $old: $!\n";
		my @old_parts;
		while (defined(my $dn = readdir($dh))) {
			if ($dn =~ /\A[0-9]+\z/) {
				push @old_parts, $dn;
			} elsif ($dn eq '.' || $dn eq '..') {
			} elsif ($dn =~ /\Aover\.sqlite3/) {
			} else {
				warn "W: skipping unknown dir: $old/$dn\n"
			}
		}
		die "No Xapian parts found in $old\n" unless @old_parts;

		my ($src, $max_part);
		if (!defined($new_parts) || $new_parts == scalar(@old_parts)) {
			# 1:1 copy
			$max_part = scalar(@old_parts) - 1;
		} else {
			# M:N copy
			$max_part = $new_parts - 1;
			$src = [ map { "$old/$_" } @old_parts ];
		}
		foreach my $dn (0..$max_part) {
			my $tmpl = "$dn-XXXXXXXX";
			my $wip = tempdir($tmpl, DIR => $old);
			same_fs_or_die($old, $wip);
			my $cur = "$old/$dn";
			push @q, [ $src // $cur , $wip ];
			$tmp->{$cur} = $wip;
		}
		# mark old parts to be unlinked
		if ($src) {
			$tmp->{$_} ||= undef for @$src;
		}
	}
	my $im = $ibx->importer(0);
	my $max = $opt->{jobs} || scalar(@q);
	$ibx->with_umask(sub {
		$im->lock_acquire;

		# fine-grained locking if we prepare for reindex
		if (!$opt->{-coarse_lock}) {
			prepare_reindex($ibx, $reindex);
			$im->lock_release;
		}

		delete($ibx->{$_}) for (qw(mm over search)); # cleanup
		process_queue(\@q, $cb, $max, $opt);
		commit_changes($ibx, $tmp, $opt);
	});
}

sub cpdb_retryable ($$) {
	my ($src, $pfx) = @_;
	if (ref($@) eq 'Search::Xapian::DatabaseModifiedError') {
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
	my ($wip) = @_; # tempdir v2: ([0-9])+-XXXXXXXX
	my @p = split('/', $wip);

	# return "xap15/0" for v2, or "xapian15" for v1:
	($p[-1] =~ /\A([0-9]+)/) ? "$p[-2]/$1" : $p[-1];
}

# xapian-compact wrapper
sub compact ($$) {
	my ($args, $opt) = @_;
	my ($src, $dst) = @$args;
	my ($r, $w);
	my $pfx = $opt->{-progress_pfx} ||= progress_pfx($src);
	my $pr = $opt->{-progress};
	my $rdr = {};

	foreach my $fd (0..2) {
		defined(my $dfd = $opt->{$fd}) or next;
		$rdr->{$fd} = $dfd;
	}
	$rdr->{1} = fileno($w) if $pr && pipe($r, $w);

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
	my $pid = spawn($cmd, undef, $rdr);
	if ($pr) {
		close $w or die "close: \$w: $!";
		foreach (<$r>) {
			s/\r/\r$pfx /g;
			$pr->("$pfx $_");
		}
	}
	my $rp = waitpid($pid, 0);
	if ($? || $rp != $pid) {
		die join(' ', @$cmd)." failed: $? (pid=$pid, reaped=$rp)\n";
	}
}

sub cpdb_loop ($$$;$$) {
	my ($src, $dst, $pr_data, $cur_part, $new_parts) = @_;
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
				if (defined $new_parts) {
					my $dst_part = $docid % $new_parts;
					next if $dst_part != $cur_part;
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
sub cpdb ($$) {
	my ($args, $opt) = @_;
	my ($old, $new) = @$args;
	my ($src, $cur_part);
	my $new_parts;
	if (ref($old) eq 'ARRAY') {
		($cur_part) = ($new =~ m!xap[0-9]+/([0-9]+)\b!);
		defined $cur_part or
			die "BUG: could not extract shard # from $new";
		$new_parts = $opt->{reshard};
		defined $new_parts or die 'BUG: got array src w/o --reshard';

		# repartitioning, M:N copy means have full read access
		foreach (@$old) {
			if ($src) {
				my $sub = Search::Xapian::Database->new($_);
				$src->add_database($sub);
			} else {
				$src = Search::Xapian::Database->new($_);
			}
		}
	} else {
		$src = Search::Xapian::Database->new($old);
	}

	my ($xtmp, $tmp);
	if ($opt->{compact}) {
		my $newdir = dirname($new);
		same_fs_or_die($newdir, $new);
		$tmp = tempdir("$new.compact-XXXXXX", DIR => $newdir);
		$xtmp = PublicInbox::Xtmpdirs->new;
		$xtmp->{$new} = $tmp;
	} else {
		$tmp = $new;
	}

	# like copydatabase(1), be sure we don't overwrite anything in case
	# of other bugs:
	my $creat = Search::Xapian::DB_CREATE();
	my $dst = Search::Xapian::WritableDatabase->new($tmp, $creat);
	my $pr = $opt->{-progress};
	my $pfx = $opt->{-progress_pfx} = progress_pfx($new);
	my $pr_data = { pr => $pr, pfx => $pfx, nr => 0 } if $pr;

	do {
		eval {
			# update the only metadata key for v1:
			my $lc = $src->get_metadata('last_commit');
			$dst->set_metadata('last_commit', $lc) if $lc;

			# only the first xapian partition (0) gets 'indexlevel'
			if ($new =~ m!(?:xapian[0-9]+|xap[0-9]+/0)\b!) {
				my $l = $src->get_metadata('indexlevel');
				if ($l eq 'medium') {
					$dst->set_metadata('indexlevel', $l);
				}
			}
			if ($pr_data) {
				my $tot = $src->get_doccount;

				# we can only estimate when repartitioning,
				# because removed spam causes slight imbalance
				my $est = '';
				if (defined $cur_part && $new_parts > 1) {
					$tot = int($tot/$new_parts);
					$est = 'around ';
				}
				my $fmt = "$pfx % ".length($tot)."u/$tot\n";
				$pr->("$pfx copying $est$tot documents\n");
				$pr_data->{fmt} = $fmt;
				$pr_data->{total} = $tot;
			}
		};
	} while (cpdb_retryable($src, $pfx));

	if (defined $new_parts) {
		# we rely on document IDs matching NNTP article number,
		# so we can't have the combined DB support rewriting
		# document IDs.  Thus we iterate through each shard
		# individually.
		$src = undef;
		foreach (@$old) {
			my $old = Search::Xapian::Database->new($_);
			cpdb_loop($old, $dst, $pr_data, $cur_part, $new_parts);
		}
	} else {
		cpdb_loop($src, $dst, $pr_data);
	}

	$pr->(sprintf($pr_data->{fmt}, $pr_data->{nr})) if $pr;
	return unless $xtmp;

	$src = $dst = undef; # flushes and closes

	# this is probably the best place to do xapian-compact
	# since $dst isn't readable by HTTP or NNTP clients, yet:
	compact([ $tmp, $new ], $opt);
	remove_tree($tmp) or die "failed to remove $tmp: $!\n";
	$xtmp->done;
}

# slightly easier-to-manage manage than END{} blocks
package PublicInbox::Xtmpdirs;
use strict;
use warnings;
use File::Path qw(remove_tree);
my %owner;

sub new {
	# http://www.tldp.org/LDP/abs/html/exitcodes.html
	$SIG{INT} = sub { exit(130) };
	$SIG{HUP} = $SIG{PIPE} = $SIG{TERM} = sub { exit(1) };
	my $self = bless {}, $_[0]; # old partition => new (tmp) partition
	$owner{"$self"} = $$;
	$self;
}

sub done {
	my ($self) = @_;
	delete $owner{"$self"};

	my %known_pids;
	$known_pids{$_}++ foreach values %owner;
	if (!$known_pids{$$}) {
		$SIG{INT} = $SIG{HUP} = $SIG{PIPE} = $SIG{TERM} = 'DEFAULT';
	}
	%$self = ();
}

sub DESTROY {
	my ($self) = @_;
	my $owner_pid = delete $owner{"$self"} or return;
	return if $owner_pid != $$;
	foreach my $new (values %$self) {
		defined $new or next; # may be undef if repartitioning
		remove_tree($new) unless -d "$new/old";
	}
	done($self);
}

1;
