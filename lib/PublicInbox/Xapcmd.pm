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

# support testing with dev versions of Xapian which installs
# commands with a version number suffix (e.g. "xapian-compact-1.5")
our $XAPIAN_COMPACT = $ENV{XAPIAN_COMPACT} || 'xapian-compact';

sub commit_changes ($$$$) {
	my ($ibx, $old, $new, $opt) = @_;

	my $reindex = $opt->{reindex};
	my $im = $ibx->importer(0);
	$im->lock_acquire if $reindex;

	my @st = stat($old) or die "failed to stat($old): $!\n";

	my $over = "$old/over.sqlite3";
	if (-f $over) {
		$over = PublicInbox::Over->new($over);
		$over->connect->sqlite_backup_to_file("$new/over.sqlite3");
		$over = undef;
	}
	rename($old, "$new/old") or die "rename $old => $new/old: $!\n";
	chmod($st[2] & 07777, $new) or die "chmod $old: $!\n";
	rename($new, $old) or die "rename $new => $old: $!\n";
	remove_tree("$old/old") or die "failed to remove $old/old: $!\n";

	if ($reindex) {
		$opt->{-skip_lock} = 1;
		PublicInbox::Admin::index_inbox($ibx, $opt);
		# implicit lock_release
	} else {
		$im->lock_release;
	}
}

sub xspawn {
	my ($cmd, $env, $opt) = @_;
	if (ref($cmd->[0]) eq 'CODE') {
		my $cb = shift(@$cmd); # $cb = cpdb()
		defined(my $pid = fork) or die "fork: $!";
		return $pid if $pid > 0;
		eval { $cb->($cmd, $env, $opt) };
		die $@ if $@;
		exit 0;
	} else {
		spawn($cmd, $env, $opt);
	}
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

sub run {
	my ($ibx, $cmd, $env, $opt) = @_;
	$opt ||= {};
	my $dir = $ibx->{mainrepo} or die "no mainrepo in inbox\n";
	my $exe = $cmd->[0];
	my $pfx = $exe;
	runnable_or_die($XAPIAN_COMPACT) if $opt->{compact};

	my $reindex; # v1:{ from => $x40 }, v2:{ from => [ $x40, $x40, .. ] } }
	my $from; # per-epoch ranges

	if (ref($exe) eq 'CODE') {
		$pfx = 'CODE';
		$reindex = $opt->{reindex} = {};
		$from = $reindex->{from} = [];
		require Search::Xapian::WritableDatabase;
	} else {
		runnable_or_die($exe);
	}
	$ibx->umask_prepare;
	my $old = $ibx->search->xdir(1);
	-d $old or die "$old does not exist\n";
	my $new = tempdir("$pfx-XXXXXXXX", DIR => $dir);
	my $v = $ibx->{version} ||= 1;
	my @cmds;
	if ($v == 1) {
		push @cmds, [@$cmd, $old, $new];
	} else {
		opendir my $dh, $old or die "Failed to opendir $old: $!\n";
		while (defined(my $dn = readdir($dh))) {
			if ($dn =~ /\A\d+\z/) {
				push @cmds, [@$cmd, "$old/$dn", "$new/$dn"];
			} elsif ($dn eq '.' || $dn eq '..') {
			} elsif ($dn =~ /\Aover\.sqlite3/) {
			} else {
				warn "W: skipping unknown dir: $old/$dn\n"
			}
		}
		die "No Xapian parts found in $old\n" unless @cmds;
	}
	my $im = $ibx->importer(0);
	my $max = $opt->{jobs} || scalar(@cmds);
	$ibx->with_umask(sub {
		$im->lock_acquire;

		# fine-grained locking if we prepare for reindex
		if ($reindex) {
			prepare_reindex($ibx, $reindex);
			$im->lock_release;
		}
		delete($ibx->{$_}) for (qw(mm over search)); # cleanup
		my %pids;
		while (@cmds) {
			while (scalar(keys(%pids)) < $max && scalar(@cmds)) {
				my $x = shift @cmds;
				$pids{xspawn($x, $env, $opt)} = $x;
			}

			while (scalar keys %pids) {
				my $pid = waitpid(-1, 0);
				my $x = delete $pids{$pid};
				die join(' ', @$x)." failed: $?\n" if $?;
			}
		}
		commit_changes($ibx, $old, $new, $opt);
	});
}

sub cpdb_retryable ($$) {
	my ($src, $err) = @_;
	if (ref($err) eq 'Search::Xapian::DatabaseModifiedError') {
		warn "$err, reopening and retrying\n";
		$src->reopen;
		return 1;
	}
	die $err if $err;
	0;
}

sub cpdb {
	my ($args, $env, $opt) = @_;
	my ($old, $new) = @$args;
	my $src = Search::Xapian::Database->new($old);
	my $tmp = $opt->{compact} ? "$new.compact" : $new;

	# like copydatabase(1), be sure we don't overwrite anything in case
	# of other bugs:
	my $creat = Search::Xapian::DB_CREATE();
	my $dst = Search::Xapian::WritableDatabase->new($tmp, $creat);
	my ($it, $end);

	do {
		eval {
			# update the only metadata key for v1:
			my $lc = $src->get_metadata('last_commit');
			$dst->set_metadata('last_commit', $lc) if $lc;

			$it = $src->postlist_begin('');
			$end = $src->postlist_end('');
		};
	} while (cpdb_retryable($src, $@));

	do {
		eval {
			while ($it != $end) {
				my $docid = $it->get_docid;
				my $doc = $src->get_document($docid);
				$dst->replace_document($docid, $doc);
				$it->inc;
			}

			# unlike copydatabase(1), we don't copy spelling
			# and synonym data (or other user metadata) since
			# the Perl APIs don't expose iterators for them
			# (and public-inbox does not use those features)
		};
	} while (cpdb_retryable($src, $@));

	return unless $opt->{compact};

	$src = $dst = undef; # flushes and closes

	# this is probably the best place to do xapian-compact
	# since $dst isn't readable by HTTP or NNTP clients, yet:
	my $cmd = [ $XAPIAN_COMPACT, '--no-renumber', $tmp, $new ];
	my $rdr = {};
	foreach my $fd (0..2) {
		defined(my $dst = $opt->{$fd}) or next;
		$rdr->{$fd} = $dst;
	}
	my $pid = spawn($cmd, $env, $rdr);
	my $r = waitpid($pid, 0);
	if ($? || $r != $pid) {
		die join(' ', @$cmd)." failed: $? (pid=$pid, reaped=$r)\n";
	}
	remove_tree($tmp) or die "failed to remove $tmp: $!\n";
}

1;
