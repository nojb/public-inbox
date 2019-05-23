# Copyright (C) 2018-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
package PublicInbox::Xapcmd;
use strict;
use warnings;
use PublicInbox::Spawn qw(which spawn);
use PublicInbox::Over;
use File::Temp qw(tempdir);
use File::Path qw(remove_tree);

sub commit_changes ($$$) {
	my ($im, $old, $new) = @_;
	my @st = stat($old) or die "failed to stat($old): $!\n";

	my $over = "$old/over.sqlite3";
	if (-f $over) {
		$over = PublicInbox::Over->new($over);
		$over->connect->sqlite_backup_to_file("$new/over.sqlite3");
	}
	rename($old, "$new/old") or die "rename $old => $new/old: $!\n";
	chmod($st[2] & 07777, $new) or die "chmod $old: $!\n";
	rename($new, $old) or die "rename $new => $old: $!\n";
	$im->lock_release;
	remove_tree("$old/old") or die "failed to remove $old/old: $!\n";
}

sub run {
	my ($ibx, $cmd) = @_;
	my $dir = $ibx->{mainrepo} or die "no mainrepo in inbox\n";
	which($cmd->[0]) or die "$cmd->[0] not found in PATH\n";
	$ibx->umask_prepare;
	my $old = $ibx->search->xdir(1);
	-d $old or die "$old does not exist\n";
	my $new = tempdir($cmd->[0].'-XXXXXXXX', CLEANUP => 1, DIR => $dir);
	my $v = $ibx->{version} || 1;
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
	$ibx->with_umask(sub {
		$im->lock_acquire;
		my %pids = map {; spawn($_) => join(' ', @$_) } @cmds;
		while (scalar keys %pids) {
			my $pid = waitpid(-1, 0);
			my $desc = delete $pids{$pid};
			die "$desc failed: $?\n" if $?;
		}
		commit_changes($im, $old, $new);
	});
}

1;
