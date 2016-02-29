# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
package PublicInbox::SpawnPP;
use strict;
use warnings;
use POSIX qw(dup2);

# Pure Perl implementation for folks that do not use Inline::C
sub public_inbox_fork_exec ($$$$$$) {
	my ($in, $out, $err, $f, $cmd, $env) = @_;
	my $pid = fork;
	if ($pid == 0) {
		if ($in != 0) {
			dup2($in, 0) or die "dup2 failed for stdin: $!";
		}
		if ($out != 1) {
			dup2($out, 1) or die "dup2 failed for stdout: $!";
		}
		if ($err != 2) {
			dup2($err, 2) or die "dup2 failed for stderr: $!";
		}
		exec qw(env -i), @$env, @$cmd;
		die "exec env -i ... $cmd->[0] failed: $!\n";
	}
	$pid;
}

1;
