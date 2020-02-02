# Copyright (C) 2016-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# This allows vfork to be used for spawning subprocesses if
# PERL_INLINE_DIRECTORY is explicitly defined in the environment.
# Under Linux, vfork can make a big difference in spawning performance
# as process size increases (fork still needs to mark pages for CoW use).
# Currently, we only use this for code intended for long running
# daemons (inside the PSGI code (-httpd) and -nntpd).  The short-lived
# scripts (-mda, -index, -learn, -init) either use IPC::run or standard
# Perl routines.

package PublicInbox::Spawn;
use strict;
use warnings;
use base qw(Exporter);
use Symbol qw(gensym);
use PublicInbox::ProcessPipe;
our @EXPORT_OK = qw/which spawn popen_rd/;
sub RLIMITS () { qw(RLIMIT_CPU RLIMIT_CORE RLIMIT_DATA) }

my $vfork_spawn = <<'VFORK_SPAWN';
#include <sys/types.h>
#include <sys/uio.h>
#include <sys/time.h>
#include <sys/resource.h>
#include <unistd.h>
#include <stdlib.h>

/* some platforms need alloca.h, but some don't */
#if defined(__GNUC__) && !defined(alloca)
#  define alloca(sz) __builtin_alloca(sz)
#endif

#include <signal.h>
#include <assert.h>

/*
 * From the av_len apidoc:
 *   Note that, unlike what the name implies, it returns
 *   the highest index in the array, so to get the size of
 *   the array you need to use "av_len(av) + 1".
 *   This is unlike "sv_len", which returns what you would expect.
 */
#define AV2C_COPY(dst, src) do { \
	I32 i; \
	I32 top_index = av_len(src); \
	I32 real_len = top_index + 1; \
	I32 capa = real_len + 1; \
	dst = alloca(capa * sizeof(char *)); \
	for (i = 0; i < real_len; i++) { \
		SV **sv = av_fetch(src, i, 0); \
		dst[i] = SvPV_nolen(*sv); \
	} \
	dst[real_len] = 0; \
} while (0)

/* needs to be safe inside a vfork'ed process */
static void exit_err(int *cerrnum)
{
	*cerrnum = errno;
	_exit(1);
}

/*
 * unstable internal API.  It'll be updated depending on
 * whatever we'll need in the future.
 * Be sure to update PublicInbox::SpawnPP if this changes
 */
int pi_fork_exec(SV *redirref, SV *file, SV *cmdref, SV *envref, SV *rlimref,
		 const char *cd)
{
	AV *redir = (AV *)SvRV(redirref);
	AV *cmd = (AV *)SvRV(cmdref);
	AV *env = (AV *)SvRV(envref);
	AV *rlim = (AV *)SvRV(rlimref);
	const char *filename = SvPV_nolen(file);
	pid_t pid;
	char **argv, **envp;
	sigset_t set, old;
	int ret, perrnum, cerrnum = 0;

	AV2C_COPY(argv, cmd);
	AV2C_COPY(envp, env);

	ret = sigfillset(&set);
	assert(ret == 0 && "BUG calling sigfillset");
	ret = sigprocmask(SIG_SETMASK, &set, &old);
	assert(ret == 0 && "BUG calling sigprocmask to block");
	pid = vfork();
	if (pid == 0) {
		int sig;
		I32 i, child_fd, max = av_len(redir);

		for (child_fd = 0; child_fd <= max; child_fd++) {
			SV **parent = av_fetch(redir, child_fd, 0);
			int parent_fd = SvIV(*parent);
			if (parent_fd == child_fd)
				continue;
			if (dup2(parent_fd, child_fd) < 0)
				exit_err(&cerrnum);
		}
		for (sig = 1; sig < NSIG; sig++)
			signal(sig, SIG_DFL); /* ignore errors on signals */
		if (*cd && chdir(cd) < 0)
			exit_err(&cerrnum);

		max = av_len(rlim);
		for (i = 0; i < max; i += 3) {
			struct rlimit rl;
			SV **res = av_fetch(rlim, i, 0);
			SV **soft = av_fetch(rlim, i + 1, 0);
			SV **hard = av_fetch(rlim, i + 2, 0);

			rl.rlim_cur = SvIV(*soft);
			rl.rlim_max = SvIV(*hard);
			if (setrlimit(SvIV(*res), &rl) < 0)
				exit_err(&cerrnum);
		}

		/*
		 * don't bother unblocking, we don't want signals
		 * to the group taking out a subprocess
		 */
		execve(filename, argv, envp);
		exit_err(&cerrnum);
	}
	perrnum = errno;
	ret = sigprocmask(SIG_SETMASK, &old, NULL);
	assert(ret == 0 && "BUG calling sigprocmask to restore");
	if (cerrnum) {
		if (pid > 0)
			waitpid(pid, NULL, 0);
		pid = -1;
		errno = cerrnum;
	} else if (perrnum) {
		errno = perrnum;
	}
	return (int)pid;
}
VFORK_SPAWN

my $inline_dir = $ENV{PERL_INLINE_DIRECTORY};
$vfork_spawn = undef unless defined $inline_dir && -d $inline_dir && -w _;
if (defined $vfork_spawn) {
	# Inline 0.64 or later has locking in multi-process env,
	# but we support 0.5 on Debian wheezy
	use Fcntl qw(:flock);
	eval {
		my $f = "$inline_dir/.public-inbox.lock";
		open my $fh, '>', $f or die "failed to open $f: $!\n";
		flock($fh, LOCK_EX) or die "LOCK_EX failed on $f: $!\n";
		eval 'use Inline C => $vfork_spawn'; #, BUILD_NOISY => 1';
		my $err = $@;
		flock($fh, LOCK_UN) or die "LOCK_UN failed on $f: $!\n";
		die $err if $err;
	};
	if ($@) {
		warn "Inline::C failed for vfork: $@\n";
		$vfork_spawn = undef;
	}
}

unless (defined $vfork_spawn) {
	require PublicInbox::SpawnPP;
	*pi_fork_exec = \&PublicInbox::SpawnPP::pi_fork_exec
}

sub which ($) {
	my ($file) = @_;
	return $file if index($file, '/') >= 0;
	foreach my $p (split(':', $ENV{PATH})) {
		$p .= "/$file";
		return $p if -x $p;
	}
	undef;
}

sub spawn ($;$$) {
	my ($cmd, $env, $opts) = @_;
	my $f = which($cmd->[0]);
	defined $f or die "$cmd->[0]: command not found\n";
	my @env;
	$opts ||= {};

	my %env = $env ? (%ENV, %$env) : %ENV;
	while (my ($k, $v) = each %env) {
		push @env, "$k=$v";
	}
	my $redir = [];
	for my $child_fd (0..2) {
		my $parent_fd = $opts->{$child_fd};
		if (defined($parent_fd) && $parent_fd !~ /\A[0-9]+\z/) {
			defined(my $fd = fileno($parent_fd)) or
					die "$parent_fd not an IO GLOB? $!";
			$parent_fd = $fd;
		}
		$redir->[$child_fd] = $parent_fd // $child_fd;
	}
	my $rlim = [];

	foreach my $l (RLIMITS()) {
		defined(my $v = $opts->{$l}) or next;
		my $r = eval "require BSD::Resource; BSD::Resource::$l();";
		unless (defined $r) {
			warn "$l undefined by BSD::Resource: $@\n";
			next;
		}
		push @$rlim, $r, @$v;
	}
	my $cd = $opts->{'-C'} // ''; # undef => NULL mapping doesn't work?
	my $pid = pi_fork_exec($redir, $f, $cmd, \@env, $rlim, $cd);
	die "fork_exec failed: $!\n" unless defined $pid;
	$pid;
}

sub popen_rd {
	my ($cmd, $env, $opts) = @_;
	pipe(my ($r, $w)) or die "pipe: $!\n";
	$opts ||= {};
	$opts->{1} = fileno($w);
	my $pid = spawn($cmd, $env, $opts);
	return ($r, $pid) if wantarray;
	my $ret = gensym;
	tie *$ret, 'PublicInbox::ProcessPipe', $pid, $r;
	$ret;
}

1;
