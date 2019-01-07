# Copyright (C) 2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# common stuff for administrative command-line tools
# Unstable internal API
package PublicInbox::Admin;
use strict;
use warnings;
use Cwd 'abs_path';
use base qw(Exporter);
our @EXPORT_OK = qw(resolve_repo_dir);

sub resolve_repo_dir {
	my ($cd, $ver) = @_;
	my $prefix = defined $cd ? $cd : './';
	if (-d $prefix && -f "$prefix/inbox.lock") { # v2
		$$ver = 2 if $ver;
		return abs_path($prefix);
	}

	my @cmd = qw(git rev-parse --git-dir);
	my $cmd = join(' ', @cmd);
	my $pid = open my $fh, '-|';
	defined $pid or die "forking $cmd failed: $!\n";
	if ($pid == 0) {
		if (defined $cd) {
			chdir $cd or die "chdir $cd failed: $!\n";
		}
		exec @cmd;
		die "Failed to exec $cmd: $!\n";
	} else {
		my $dir = eval {
			local $/;
			<$fh>;
		};
		close $fh or die "error in $cmd: $!\n";
		chomp $dir;
		$$ver = 1 if $ver;
		return abs_path($cd) if ($dir eq '.' && defined $cd);
		abs_path($dir);
	}
}

1;
