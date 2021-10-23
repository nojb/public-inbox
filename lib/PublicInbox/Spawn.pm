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
use Fcntl qw(LOCK_EX SEEK_SET);
use IO::Handle ();
use PublicInbox::ProcessPipe;
our @EXPORT_OK = qw(which spawn popen_rd run_die nodatacow_dir);
our @RLIMITS = qw(RLIMIT_CPU RLIMIT_CORE RLIMIT_DATA);

BEGIN {
	my $all_libc = <<'ALL_LIBC'; # all *nix systems we support
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/time.h>
#include <sys/uio.h>
#include <unistd.h>
#include <stdlib.h>
#include <errno.h>
#include <time.h>
#include <stdio.h>
#include <string.h>

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
static void exit_err(const char *fn, volatile int *cerrnum)
{
	*cerrnum = errno;
	write(2, fn, strlen(fn));
	_exit(1);
}

/*
 * unstable internal API.  It'll be updated depending on
 * whatever we'll need in the future.
 * Be sure to update PublicInbox::SpawnPP if this changes
 */
int pi_fork_exec(SV *redirref, SV *file, SV *cmdref, SV *envref, SV *rlimref,
		 const char *cd, int pgid)
{
	AV *redir = (AV *)SvRV(redirref);
	AV *cmd = (AV *)SvRV(cmdref);
	AV *env = (AV *)SvRV(envref);
	AV *rlim = (AV *)SvRV(rlimref);
	const char *filename = SvPV_nolen(file);
	pid_t pid;
	char **argv, **envp;
	sigset_t set, old;
	int ret, perrnum;
	volatile int cerrnum = 0; /* shared due to vfork */
	int chld_is_member;
	I32 max_fd = av_len(redir);

	AV2C_COPY(argv, cmd);
	AV2C_COPY(envp, env);

	if (sigfillset(&set)) return -1;
	if (sigprocmask(SIG_SETMASK, &set, &old)) return -1;
	chld_is_member = sigismember(&old, SIGCHLD);
	if (chld_is_member < 0) return -1;
	if (chld_is_member > 0)
		sigdelset(&old, SIGCHLD);

	pid = vfork();
	if (pid == 0) {
		int sig;
		I32 i, child_fd, max_rlim;

		for (child_fd = 0; child_fd <= max_fd; child_fd++) {
			SV **parent = av_fetch(redir, child_fd, 0);
			int parent_fd = SvIV(*parent);
			if (parent_fd == child_fd)
				continue;
			if (dup2(parent_fd, child_fd) < 0)
				exit_err("dup2", &cerrnum);
		}
		if (pgid >= 0 && setpgid(0, pgid) < 0)
			exit_err("setpgid", &cerrnum);
		for (sig = 1; sig < NSIG; sig++)
			signal(sig, SIG_DFL); /* ignore errors on signals */
		if (*cd && chdir(cd) < 0)
			exit_err("chdir", &cerrnum);

		max_rlim = av_len(rlim);
		for (i = 0; i < max_rlim; i += 3) {
			struct rlimit rl;
			SV **res = av_fetch(rlim, i, 0);
			SV **soft = av_fetch(rlim, i + 1, 0);
			SV **hard = av_fetch(rlim, i + 2, 0);

			rl.rlim_cur = SvIV(*soft);
			rl.rlim_max = SvIV(*hard);
			if (setrlimit(SvIV(*res), &rl) < 0)
				exit_err("setrlimit", &cerrnum);
		}

		(void)sigprocmask(SIG_SETMASK, &old, NULL);
		execve(filename, argv, envp);
		exit_err("execve", &cerrnum);
	}
	perrnum = errno;
	if (chld_is_member > 0)
		sigaddset(&old, SIGCHLD);
	ret = sigprocmask(SIG_SETMASK, &old, NULL);
	assert(ret == 0 && "BUG calling sigprocmask to restore");
	if (cerrnum) {
		int err_fd = STDERR_FILENO;
		if (err_fd <= max_fd) {
			SV **parent = av_fetch(redir, err_fd, 0);
			err_fd = SvIV(*parent);
		}
		if (pid > 0)
			waitpid(pid, NULL, 0);
		pid = -1;
		/* continue message started by exit_err in child */
		dprintf(err_fd, ": %s\n", strerror(cerrnum));
		errno = cerrnum;
	} else if (perrnum) {
		errno = perrnum;
	}
	return (int)pid;
}

static int sleep_wait(unsigned *try, int err)
{
	const struct timespec req = { 0, 100000000 }; /* 100ms */
	switch (err) {
	case ENOBUFS: case ENOMEM: case ETOOMANYREFS:
		if (++*try < 50) {
			fprintf(stderr, "sleeping on sendmsg: %s (#%u)\n",
				strerror(err), *try);
			nanosleep(&req, NULL);
			return 1;
		}
	default:
		return 0;
	}
}

#if defined(CMSG_SPACE) && defined(CMSG_LEN)
#define SEND_FD_CAPA 10
#define SEND_FD_SPACE (SEND_FD_CAPA * sizeof(int))
union my_cmsg {
	struct cmsghdr hdr;
	char pad[sizeof(struct cmsghdr) + 16 + SEND_FD_SPACE];
};

SV *send_cmd4(PerlIO *s, SV *svfds, SV *data, int flags)
{
	struct msghdr msg = { 0 };
	union my_cmsg cmsg = { 0 };
	STRLEN dlen = 0;
	struct iovec iov;
	ssize_t sent;
	AV *fds = (AV *)SvRV(svfds);
	I32 i, nfds = av_len(fds) + 1;
	int *fdp;
	unsigned try = 0;

	if (SvOK(data)) {
		iov.iov_base = SvPV(data, dlen);
		iov.iov_len = dlen;
	}
	if (!dlen) { /* must be non-zero */
		iov.iov_base = &msg.msg_namelen; /* whatever */
		iov.iov_len = 1;
	}
	msg.msg_iov = &iov;
	msg.msg_iovlen = 1;
	if (nfds) {
		if (nfds > SEND_FD_CAPA) {
			fprintf(stderr, "FIXME: bump SEND_FD_CAPA=%d\n", nfds);
			nfds = SEND_FD_CAPA;
		}
		msg.msg_control = &cmsg.hdr;
		msg.msg_controllen = CMSG_SPACE(nfds * sizeof(int));
		cmsg.hdr.cmsg_level = SOL_SOCKET;
		cmsg.hdr.cmsg_type = SCM_RIGHTS;
		cmsg.hdr.cmsg_len = CMSG_LEN(nfds * sizeof(int));
		fdp = (int *)CMSG_DATA(&cmsg.hdr);
		for (i = 0; i < nfds; i++) {
			SV **fd = av_fetch(fds, i, 0);
			*fdp++ = SvIV(*fd);
		}
	}
	do {
		sent = sendmsg(PerlIO_fileno(s), &msg, flags);
	} while (sent < 0 && sleep_wait(&try, errno));
	return sent >= 0 ? newSViv(sent) : &PL_sv_undef;
}

void recv_cmd4(PerlIO *s, SV *buf, STRLEN n)
{
	union my_cmsg cmsg = { 0 };
	struct msghdr msg = { 0 };
	struct iovec iov;
	ssize_t i;
	Inline_Stack_Vars;
	Inline_Stack_Reset;

	if (!SvOK(buf))
		sv_setpvn(buf, "", 0);
	iov.iov_base = SvGROW(buf, n + 1);
	iov.iov_len = n;
	msg.msg_iov = &iov;
	msg.msg_iovlen = 1;
	msg.msg_control = &cmsg.hdr;
	msg.msg_controllen = CMSG_SPACE(SEND_FD_SPACE);

	i = recvmsg(PerlIO_fileno(s), &msg, 0);
	if (i < 0)
		Inline_Stack_Push(&PL_sv_undef);
	else
		SvCUR_set(buf, i);
	if (i > 0 && cmsg.hdr.cmsg_level == SOL_SOCKET &&
			cmsg.hdr.cmsg_type == SCM_RIGHTS) {
		size_t len = cmsg.hdr.cmsg_len;
		int *fdp = (int *)CMSG_DATA(&cmsg.hdr);
		for (i = 0; CMSG_LEN((i + 1) * sizeof(int)) <= len; i++)
			Inline_Stack_Push(sv_2mortal(newSViv(*fdp++)));
	}
	Inline_Stack_Done;
}
#endif /* defined(CMSG_SPACE) && defined(CMSG_LEN) */
ALL_LIBC

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

	my $inline_dir = $ENV{PERL_INLINE_DIRECTORY} //= (
			$ENV{XDG_CACHE_HOME} //
			( ($ENV{HOME} // '/nonexistent').'/.cache' )
		).'/public-inbox/inline-c';
	warn "$inline_dir exists, not writable\n" if -e $inline_dir && !-w _;
	$set_nodatacow = $all_libc = undef unless -d _ && -w _;
	if (defined $all_libc) {
		my $f = "$inline_dir/.public-inbox.lock";
		open my $oldout, '>&', \*STDOUT or die "dup(1): $!";
		open my $olderr, '>&', \*STDERR or die "dup(2): $!";
		open my $fh, '+>', $f or die "open($f): $!";
		open STDOUT, '>&', $fh or die "1>$f: $!";
		open STDERR, '>&', $fh or die "2>$f: $!";
		STDERR->autoflush(1);
		STDOUT->autoflush(1);

		# CentOS 7.x ships Inline 0.53, 0.64+ has built-in locking
		flock($fh, LOCK_EX) or die "LOCK_EX($f): $!";
		eval <<'EOM';
use Inline C => $all_libc.$set_nodatacow, BUILD_NOISY => 1;
EOM
		my $err = $@;
		my $ndc_err = '';
		if ($err && $set_nodatacow) { # missing Linux kernel headers
			$ndc_err = "with set_nodatacow: <\n$err\n>\n";
			undef $set_nodatacow;
			eval <<'EOM';
use Inline C => $all_libc, BUILD_NOISY => 1;
EOM
		};
		$err = $@;
		open(STDERR, '>&', $olderr) or warn "restore stderr: $!";
		open(STDOUT, '>&', $oldout) or warn "restore stdout: $!";
		if ($err) {
			seek($fh, 0, SEEK_SET);
			my @msg = <$fh>;
			warn "Inline::C build failed:\n",
				$ndc_err, $err, "\n", @msg;
			$set_nodatacow = $all_libc = undef;
		} elsif ($ndc_err) {
			warn "Inline::C build succeeded w/o set_nodatacow\n",
				"error $ndc_err";
		}
	}
	unless ($all_libc) {
		require PublicInbox::SpawnPP;
		*pi_fork_exec = \&PublicInbox::SpawnPP::pi_fork_exec
	}
	unless ($set_nodatacow) {
		require PublicInbox::NDC_PP;
		no warnings 'once';
		*nodatacow_fd = \&PublicInbox::NDC_PP::nodatacow_fd;
		*nodatacow_dir = \&PublicInbox::NDC_PP::nodatacow_dir;
	}
} # /BEGIN

sub which ($) {
	my ($file) = @_;
	return $file if index($file, '/') >= 0;
	for my $p (split(/:/, $ENV{PATH})) {
		$p .= "/$file";
		return $p if -x $p;
	}
	undef;
}

sub spawn ($;$$) {
	my ($cmd, $env, $opts) = @_;
	my $f = which($cmd->[0]) // die "$cmd->[0]: command not found\n";
	my @env;
	$opts ||= {};
	my %env = (%ENV, $env ? %$env : ());
	while (my ($k, $v) = each %env) {
		push @env, "$k=$v" if defined($v);
	}
	my $redir = [];
	for my $child_fd (0..2) {
		my $parent_fd = $opts->{$child_fd};
		if (defined($parent_fd) && $parent_fd !~ /\A[0-9]+\z/) {
			my $fd = fileno($parent_fd) //
					die "$parent_fd not an IO GLOB? $!";
			$parent_fd = $fd;
		}
		$redir->[$child_fd] = $parent_fd // $child_fd;
	}
	my $rlim = [];

	foreach my $l (@RLIMITS) {
		my $v = $opts->{$l} // next;
		my $r = eval "require BSD::Resource; BSD::Resource::$l();";
		unless (defined $r) {
			warn "$l undefined by BSD::Resource: $@\n";
			next;
		}
		push @$rlim, $r, @$v;
	}
	my $cd = $opts->{'-C'} // ''; # undef => NULL mapping doesn't work?
	my $pgid = $opts->{pgid} // -1;
	my $pid = pi_fork_exec($redir, $f, $cmd, \@env, $rlim, $cd, $pgid);
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
