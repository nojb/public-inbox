# Copyright (C) 2016-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# This allows vfork to be used for spawning subprocesses if
# ~/.cache/public-inbox/inline-c is writable or if PERL_INLINE_DIRECTORY
# is explicitly defined in the environment (and writable).
# Under Linux, vfork can make a big difference in spawning performance
# as process size increases (fork still needs to mark pages for CoW use).
# Currently, we only use this for code intended for long running
# daemons (inside the PSGI code (-httpd) and -nntpd).  The short-lived
# scripts (-mda, -index, -learn, -init) either use IPC::run or standard
# Perl routines.
#
# There'll probably be more OS-level C stuff here, down the line.
# We don't want too many DSOs: https://udrepper.livejournal.com/8790.html

package PublicInbox::Spawn;
use strict;
use parent qw(Exporter);
use Symbol qw(gensym);
use PublicInbox::ProcessPipe;
our @EXPORT_OK = qw(which spawn popen_rd run_die nodatacow_dir);
our @RLIMITS = qw(RLIMIT_CPU RLIMIT_CORE RLIMIT_DATA);

my $vfork_spawn = <<'VFORK_SPAWN';
#include <sys/types.h>
#include <sys/time.h>
#include <sys/resource.h>
#include <unistd.h>
#include <stdlib.h>
#include <errno.h>

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
	sigset_t set, old, cset;
	int ret, perrnum, cerrnum = 0;

	AV2C_COPY(argv, cmd);
	AV2C_COPY(envp, env);

	ret = sigfillset(&set);
	assert(ret == 0 && "BUG calling sigfillset");
	ret = sigprocmask(SIG_SETMASK, &set, &old);
	assert(ret == 0 && "BUG calling sigprocmask to block");
	ret = sigemptyset(&cset);
	assert(ret == 0 && "BUG calling sigemptyset");
	ret = sigaddset(&cset, SIGCHLD);
	assert(ret == 0 && "BUG calling sigaddset for SIGCHLD");
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
		 * don't bother unblocking other signals for now, just SIGCHLD.
		 * we don't want signals to the group taking out a subprocess
		 */
		(void)sigprocmask(SIG_UNBLOCK, &cset, NULL);
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

# btrfs on Linux is copy-on-write (COW) by default.  As of Linux 5.7,
# this still leads to fragmentation for SQLite and Xapian files where
# random I/O happens, so we disable COW just for SQLite files and Xapian
# directories.  Disabling COW disables checksumming, so we only do this
# for regeneratable files, and not canonical git storage (git doesn't
# checksum refs, only data under $GIT_DIR/objects).
my $set_nodatacow = $^O eq 'linux' ? <<'SET_NODATACOW' : '';
#include <sys/ioctl.h>
#include <sys/vfs.h>
#include <linux/magic.h>
#include <linux/fs.h>
#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>

void nodatacow_fd(int fd)
{
	struct statfs buf;
	int val = 0;

	if (fstatfs(fd, &buf) < 0) {
		fprintf(stderr, "fstatfs: %s\\n", strerror(errno));
		return;
	}

	/* only btrfs is known to have this problem, so skip for non-btrfs */
	if (buf.f_type != BTRFS_SUPER_MAGIC)
		return;

	if (ioctl(fd, FS_IOC_GETFLAGS, &val) < 0) {
		fprintf(stderr, "FS_IOC_GET_FLAGS: %s\\n", strerror(errno));
		return;
	}
	val |= FS_NOCOW_FL;
	if (ioctl(fd, FS_IOC_SETFLAGS, &val) < 0)
		fprintf(stderr, "FS_IOC_SET_FLAGS: %s\\n", strerror(errno));
}

void nodatacow_dir(const char *dir)
{
	DIR *dh = opendir(dir);
	int fd;

	if (!dh) croak("opendir(%s): %s", dir, strerror(errno));
	fd = dirfd(dh);
	if (fd >= 0)
		nodatacow_fd(fd);
	/* ENOTSUP probably won't happen under Linux... */
	closedir(dh);
}
SET_NODATACOW

my $fdpass = <<'FDPASS';
#include <sys/types.h>
#include <sys/uio.h>
#include <sys/socket.h>

#if defined(CMSG_SPACE) && defined(CMSG_LEN)
struct my_3fds { int fds[3]; };
union my_cmsg {
	struct cmsghdr hdr;
	char pad[sizeof(struct cmsghdr)+ 8 + sizeof(struct my_3fds) + 8];
};

int send_3fds(int sockfd, int infd, int outfd, int errfd)
{
	struct msghdr msg = { 0 };
	struct iovec iov;
	union my_cmsg cmsg = { 0 };
	int *fdp;
	size_t i;

	iov.iov_base = &msg.msg_namelen; /* whatever */
	iov.iov_len = 1;
	msg.msg_iov = &iov;
	msg.msg_iovlen = 1;
	msg.msg_control = &cmsg.hdr;
	msg.msg_controllen = CMSG_SPACE(sizeof(struct my_3fds));

	cmsg.hdr.cmsg_level = SOL_SOCKET;
	cmsg.hdr.cmsg_type = SCM_RIGHTS;
	cmsg.hdr.cmsg_len = CMSG_LEN(sizeof(struct my_3fds));
	fdp = (int *)CMSG_DATA(&cmsg.hdr);
	*fdp++ = infd;
	*fdp++ = outfd;
	*fdp++ = errfd;
	return sendmsg(sockfd, &msg, 0) >= 0;
}

void recv_3fds(int sockfd)
{
	union my_cmsg cmsg = { 0 };
	struct msghdr msg = { 0 };
	struct iovec iov;
	size_t i;
	Inline_Stack_Vars;

	iov.iov_base = &msg.msg_namelen; /* whatever */
	iov.iov_len = 1;
	msg.msg_iov = &iov;
	msg.msg_iovlen = 1;
	msg.msg_control = &cmsg.hdr;
	msg.msg_controllen = CMSG_SPACE(sizeof(struct my_3fds));

	if (recvmsg(sockfd, &msg, 0) <= 0)
		return;

	errno = EDOM;
	Inline_Stack_Reset;
	if (cmsg.hdr.cmsg_level == SOL_SOCKET &&
			cmsg.hdr.cmsg_type == SCM_RIGHTS &&
			cmsg.hdr.cmsg_len == CMSG_LEN(sizeof(struct my_3fds))) {
		int *fdp = (int *)CMSG_DATA(&cmsg.hdr);
		size_t i;

		for (i = 0; i < 3; i++)
			Inline_Stack_Push(sv_2mortal(newSViv(*fdp++)));
	}
	Inline_Stack_Done;
}
#endif /* defined(CMSG_SPACE) && defined(CMSG_LEN) */
FDPASS

my $inline_dir = $ENV{PERL_INLINE_DIRECTORY} //= (
		$ENV{XDG_CACHE_HOME} //
		( ($ENV{HOME} // '/nonexistent').'/.cache' )
	).'/public-inbox/inline-c';

$set_nodatacow = $vfork_spawn = $fdpass = undef unless -d $inline_dir && -w _;
if (defined $vfork_spawn) {
	# Inline 0.64 or later has locking in multi-process env,
	# but we support 0.5 on Debian wheezy
	use Fcntl qw(:flock);
	eval {
		my $f = "$inline_dir/.public-inbox.lock";
		open my $fh, '>', $f or die "failed to open $f: $!\n";
		flock($fh, LOCK_EX) or die "LOCK_EX failed on $f: $!\n";
		eval 'use Inline C => $vfork_spawn.$fdpass.$set_nodatacow';
			# . ', BUILD_NOISY => 1';
		my $err = $@;
		my $ndc_err;
		if ($err && $set_nodatacow) { # missing Linux kernel headers
			$ndc_err = $err;
			undef $set_nodatacow;
			eval 'use Inline C => $vfork_spawn . $fdpass';
		}
		flock($fh, LOCK_UN) or die "LOCK_UN failed on $f: $!\n";
		die $err if $err;
		warn $ndc_err if $ndc_err;
	};
	if ($@) {
		warn "Inline::C failed for vfork: $@\n";
		$set_nodatacow = $vfork_spawn = $fdpass = undef;
	}
}

unless (defined $vfork_spawn) {
	require PublicInbox::SpawnPP;
	*pi_fork_exec = \&PublicInbox::SpawnPP::pi_fork_exec
}
unless ($set_nodatacow) {
	require PublicInbox::NDC_PP;
	no warnings 'once';
	*nodatacow_fd = \&PublicInbox::NDC_PP::nodatacow_fd;
	*nodatacow_dir = \&PublicInbox::NDC_PP::nodatacow_dir;
}

undef $set_nodatacow;
undef $vfork_spawn;
undef $fdpass;

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

	foreach my $l (@RLIMITS) {
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
	die "fork_exec @$cmd failed: $!\n" unless $pid > 0;
	$pid;
}

sub popen_rd {
	my ($cmd, $env, $opt) = @_;
	pipe(my ($r, $w)) or die "pipe: $!\n";
	$opt ||= {};
	$opt->{1} = fileno($w);
	my $pid = spawn($cmd, $env, $opt);
	return ($r, $pid) if wantarray;
	my $ret = gensym;
	tie *$ret, 'PublicInbox::ProcessPipe', $pid, $r, @$opt{qw(cb arg)};
	$ret;
}

sub run_die ($;$$) {
	my ($cmd, $env, $rdr) = @_;
	my $pid = spawn($cmd, $env, $rdr);
	waitpid($pid, 0) == $pid or die "@$cmd did not finish";
	$? == 0 or die "@$cmd failed: \$?=$?\n";
}

1;
