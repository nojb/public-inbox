# Copyright (C) 2015-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# contains common daemon code for the nntpd and httpd servers.
# This may be used for read-only IMAP server if we decide to implement it.
package PublicInbox::Daemon;
use strict;
use warnings;
use Getopt::Long qw/:config gnu_getopt no_ignore_case auto_abbrev/;
use IO::Handle;
use IO::Socket;
use Cwd qw/abs_path/;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
STDOUT->autoflush(1);
STDERR->autoflush(1);
require Danga::Socket;
require POSIX;
require PublicInbox::Listener;
require PublicInbox::ParentPipe;
my @CMD;
my $set_user;
my (@cfg_listen, $stdout, $stderr, $group, $user, $pid_file, $daemonize);
my $worker_processes = 1;
my @listeners;
my %pids;
my %listener_names;
my $reexec_pid;
my $cleanup;
my ($uid, $gid);
END { $cleanup->() if $cleanup };

sub daemon_prepare ($) {
	my ($default_listen) = @_;
	@CMD = ($0, @ARGV);
	$SIG{HUP} = $SIG{USR1} = $SIG{USR2} = $SIG{PIPE} =
		$SIG{TTIN} = $SIG{TTOU} = $SIG{WINCH} = 'IGNORE';
	my %opts = (
		'l|listen=s' => \@cfg_listen,
		'1|stdout=s' => \$stdout,
		'2|stderr=s' => \$stderr,
		'W|worker-processes=i' => \$worker_processes,
		'P|pid-file=s' => \$pid_file,
		'u|user=s' => \$user,
		'g|group=s' => \$group,
		'D|daemonize' => \$daemonize,
	);
	GetOptions(%opts) or die "bad command-line args\n";

	if (defined $pid_file && $pid_file =~ /\.oldbin\z/) {
		die "--pid-file cannot end with '.oldbin'\n";
	}
	@listeners = inherit();
	# ignore daemonize when inheriting
	$daemonize = undef if scalar @listeners;

	push @cfg_listen, $default_listen unless (@listeners || @cfg_listen);

	foreach my $l (@cfg_listen) {
		next if $listener_names{$l}; # already inherited
		my (%o, $sock_pkg);
		if (index($l, '/') == 0) {
			$sock_pkg = 'IO::Socket::UNIX';
			eval "use $sock_pkg";
			die $@ if $@;
			%o = (Type => SOCK_STREAM, Peer => $l);
			if (-S $l) {
				my $c = $sock_pkg->new(%o);
				if (!defined($c) && $!{ECONNREFUSED}) {
					unlink $l or die
"failed to unlink stale socket=$l: $!\n";
				} # else: let the bind fail
			}
			$o{Local} = delete $o{Peer};
		} else {
			# both work for IPv4, too
			for (qw(IO::Socket::IP IO::Socket::INET6)) {
				$sock_pkg = $_;
				eval "use $sock_pkg";
				$@ or last;
			}
			die $@ if $@;
			%o = (LocalAddr => $l, ReuseAddr => 1, Proto => 'tcp');
		}
		$o{Listen} = 1024;
		my $prev = umask 0000;
		my $s = eval { $sock_pkg->new(%o) };
		warn "error binding $l: $! ($@)\n" unless $s;
		umask $prev;

		if ($s) {
			$listener_names{sockname($s)} = $s;
			push @listeners, $s;
		}
	}
	die "No listeners bound\n" unless @listeners;
}

sub check_absolute ($$) {
	my ($var, $val) = @_;
	if (defined $val && index($val, '/') != 0) {
		die
"--$var must be an absolute path when using --daemonize: $val\n";
	}
}

sub daemonize () {
	if ($daemonize) {
		foreach my $i (0..$#ARGV) {
			my $arg = $ARGV[$i];
			next unless -e $arg;
			$ARGV[$i] = abs_path($arg);
		}
		check_absolute('stdout', $stdout);
		check_absolute('stderr', $stderr);
		check_absolute('pid-file', $pid_file);

		chdir '/' or die "chdir failed: $!";
	}

	return unless (defined $pid_file || defined $group || defined $user
			|| $daemonize);

	eval { require Net::Server::Daemonize };
	if ($@) {
		die
"Net::Server required for --pid-file, --group, --user, and --daemonize\n$@\n";
	}

	Net::Server::Daemonize::check_pid_file($pid_file) if defined $pid_file;
	$uid = Net::Server::Daemonize::get_uid($user) if defined $user;
	if (defined $group) {
		$gid = Net::Server::Daemonize::get_gid($group);
		$gid = (split /\s+/, $gid)[0];
	} elsif (defined $uid) {
		$gid = (getpwuid($uid))[3];
	}

	# We change users in the worker to ensure upgradability,
	# The upgrade will create the ".oldbin" pid file in the
	# same directory as the given pid file.
	$uid and $set_user = sub {
		$set_user = undef;
		Net::Server::Daemonize::set_user($uid, $gid);
	};

	if ($daemonize) {
		my $pid = fork;
		die "could not fork: $!\n" unless defined $pid;
		exit if $pid;

		open(STDIN, '+<', '/dev/null') or
					die "redirect stdin failed: $!\n";
		open STDOUT, '>&STDIN' or die "redirect stdout failed: $!\n";
		open STDERR, '>&STDIN' or die "redirect stderr failed: $!\n";
		POSIX::setsid();
		$pid = fork;
		die "could not fork: $!\n" unless defined $pid;
		exit if $pid;
	}
	if (defined $pid_file) {
		write_pid($pid_file);
		my $unlink_pid = $$;
		$cleanup = sub {
			$cleanup = undef; # avoid cyclic reference
			unlink_pid_file_safe_ish($unlink_pid, $pid_file);
		};
	}
}


sub worker_quit {
	my ($reason) = @_;
	# killing again terminates immediately:
	exit unless @listeners;

	$_->close foreach @listeners; # call Danga::Socket::close
	@listeners = ();
	$reason->close if ref($reason) eq 'PublicInbox::ParentPipe';

	my $proc_name;
	my $warn = 0;
	# drop idle connections and try to quit gracefully
	Danga::Socket->SetPostLoopCallback(sub {
		my ($dmap, undef) = @_;
		my $n = 0;
		my $now = clock_gettime(CLOCK_MONOTONIC);

		foreach my $s (values %$dmap) {
			$s->can('busy') or next;
			if ($s->busy($now)) {
				++$n;
			} else {
				# close as much as possible, early as possible
				$s->close;
			}
		}
		if ($n) {
			if (($warn + 5) < time) {
				warn "$$ quitting, $n client(s) left\n";
				$warn = time;
			}
			unless (defined $proc_name) {
				$proc_name = (split(/\s+/, $0))[0];
				$proc_name =~ s!\A.*?([^/]+)\z!$1!;
			}
			$0 = "$proc_name quitting, $n client(s) left";
		}
		$n; # true: loop continues, false: loop breaks
	});
}

sub reopen_logs {
	if ($stdout) {
		open STDOUT, '>>', $stdout or
			warn "failed to redirect stdout to $stdout: $!\n";
		STDOUT->autoflush(1);
		do_chown($stdout);
	}
	if ($stderr) {
		open STDERR, '>>', $stderr or
			warn "failed to redirect stderr to $stderr: $!\n";
		STDERR->autoflush(1);
		do_chown($stderr);
	}
}

sub sockname ($) {
	my ($s) = @_;
	my $addr = getsockname($s) or return;
	my ($host, $port) = host_with_port($addr);
	if ($port == 0 && $host eq '127.0.0.1') {
		my ($path) = Socket::sockaddr_un($addr);
		return $path;
	}
	"$host:$port";
}

sub host_with_port ($) {
	my ($addr) = @_;
	my ($port, $host);

	# this eval will die on Unix sockets:
	eval {
		if (length($addr) >= 28) {
			require Socket6;
			($port, $host) = Socket6::unpack_sockaddr_in6($addr);
			$host = Socket6::inet_ntop(Socket6::AF_INET6(), $host);
			$host = "[$host]";
		} else {
			($port, $host) = Socket::sockaddr_in($addr);
			$host = Socket::inet_ntoa($host);
		}
	};
	$@ ? ('127.0.0.1', 0) : ($host, $port);
}

sub inherit () {
	return () if ($ENV{LISTEN_PID} || 0) != $$;
	my $fds = $ENV{LISTEN_FDS} or return ();
	my $end = $fds + 2; # LISTEN_FDS_START - 1
	my @rv = ();
	foreach my $fd (3..$end) {
		my $s = IO::Handle->new_from_fd($fd, 'r');
		if (my $k = sockname($s)) {
			$listener_names{$k} = $s;
			push @rv, $s;
		} else {
			warn "failed to inherit fd=$fd (LISTEN_FDS=$fds)";
		}
	}
	@rv
}

sub upgrade () {
	if ($reexec_pid) {
		warn "upgrade in-progress: $reexec_pid\n";
		return;
	}
	if (defined $pid_file) {
		if ($pid_file =~ /\.oldbin\z/) {
			warn "BUG: .oldbin suffix exists: $pid_file\n";
			return;
		}
		unlink_pid_file_safe_ish($$, $pid_file);
		$pid_file .= '.oldbin';
		write_pid($pid_file);
	}
	my $pid = fork;
	unless (defined $pid) {
		warn "fork failed: $!\n";
		return;
	}
	if ($pid == 0) {
		use Fcntl qw(FD_CLOEXEC F_SETFD F_GETFD);
		$ENV{LISTEN_FDS} = scalar @listeners;
		$ENV{LISTEN_PID} = $$;
		foreach my $s (@listeners) {
			my $fl = fcntl($s, F_GETFD, 0);
			fcntl($s, F_SETFD, $fl &= ~FD_CLOEXEC);
		}
		exec @CMD;
		die "Failed to exec: $!\n";
	}
	$reexec_pid = $pid;
}

sub kill_workers ($) {
	my ($s) = @_;

	while (my ($pid, $id) = each %pids) {
		kill $s, $pid;
	}
}

sub upgrade_aborted ($) {
	my ($p) = @_;
	warn "reexec PID($p) died with: $?\n";
	$reexec_pid = undef;
	return unless $pid_file;

	my $file = $pid_file;
	$file =~ s/\.oldbin\z// or die "BUG: no '.oldbin' suffix in $file";
	unlink_pid_file_safe_ish($$, $pid_file);
	$pid_file = $file;
	eval { write_pid($pid_file) };
	warn $@, "\n" if $@;
}

sub reap_children () {
	while (1) {
		my $p = waitpid(-1, &POSIX::WNOHANG) or return;
		if (defined $reexec_pid && $p == $reexec_pid) {
			upgrade_aborted($p);
		} elsif (defined(my $id = delete $pids{$p})) {
			warn "worker[$id] PID($p) died with: $?\n";
		} elsif ($p > 0) {
			warn "unknown PID($p) reaped: $?\n";
		} else {
			return;
		}
	}
}

sub unlink_pid_file_safe_ish ($$) {
	my ($unlink_pid, $file) = @_;
	return unless defined $unlink_pid && $unlink_pid == $$;

	open my $fh, '<', $file or return;
	local $/ = "\n";
	defined(my $read_pid = <$fh>) or return;
	chomp $read_pid;
	if ($read_pid == $unlink_pid) {
		Net::Server::Daemonize::unlink_pid_file($file);
	}
}

sub master_loop {
	pipe(my ($p0, $p1)) or die "failed to create parent-pipe: $!";
	pipe(my ($r, $w)) or die "failed to create self-pipe: $!";
	IO::Handle::blocking($w, 0);
	my $set_workers = $worker_processes;
	my @caught;
	my $master_pid = $$;
	foreach my $s (qw(HUP CHLD QUIT INT TERM USR1 USR2 TTIN TTOU WINCH)) {
		$SIG{$s} = sub {
			return if $$ != $master_pid;
			push @caught, $s;
			syswrite($w, '.');
		};
	}
	reopen_logs();
	# main loop
	my $quit = 0;
	while (1) {
		while (my $s = shift @caught) {
			if ($s eq 'USR1') {
				reopen_logs();
				kill_workers($s);
			} elsif ($s eq 'USR2') {
				upgrade();
			} elsif ($s =~ /\A(?:QUIT|TERM|INT)\z/) {
				exit if $quit++;
				kill_workers($s);
			} elsif ($s eq 'WINCH') {
				if (-t STDIN || -t STDOUT || -t STDERR) {
					warn
"ignoring SIGWINCH since we are not daemonized\n";
					$SIG{WINCH} = 'IGNORE';
				} else {
					$worker_processes = 0;
				}
			} elsif ($s eq 'HUP') {
				$worker_processes = $set_workers;
				kill_workers($s);
			} elsif ($s eq 'TTIN') {
				if ($set_workers > $worker_processes) {
					++$worker_processes;
				} else {
					$worker_processes = ++$set_workers;
				}
			} elsif ($s eq 'TTOU') {
				if ($set_workers > 0) {
					$worker_processes = --$set_workers;
				}
			} elsif ($s eq 'CHLD') {
				reap_children();
			}
		}

		my $n = scalar keys %pids;
		if ($quit) {
			exit if $n == 0;
			$set_workers = $worker_processes = $n = 0;
		}

		if ($n > $worker_processes) {
			while (my ($k, $v) = each %pids) {
				kill('TERM', $k) if $v >= $worker_processes;
			}
			$n = $worker_processes;
		}
		foreach my $i ($n..($worker_processes - 1)) {
			my $pid = fork;
			if (!defined $pid) {
				warn "failed to fork worker[$i]: $!\n";
			} elsif ($pid == 0) {
				$set_user->() if $set_user;
				return $p0; # run normal work code
			} else {
				warn "PID=$pid is worker[$i]\n";
				$pids{$pid} = $i;
			}
		}
		# just wait on signal events here:
		sysread($r, my $buf, 8);
	}
	exit # never gets here, just for documentation
}

sub daemon_loop ($$) {
	my ($refresh, $post_accept) = @_;
	my $parent_pipe;
	if ($worker_processes > 0) {
		$refresh->(); # preload by default
		my $fh = master_loop(); # returns if in child process
		$parent_pipe = PublicInbox::ParentPipe->new($fh, *worker_quit);
	} else {
		reopen_logs();
		$set_user->() if $set_user;
		$SIG{USR2} = sub { worker_quit('USR2') if upgrade() };
		$refresh->();
	}
	$uid = $gid = undef;
	reopen_logs();
	$SIG{QUIT} = $SIG{INT} = $SIG{TERM} = *worker_quit;
	$SIG{USR1} = *reopen_logs;
	$SIG{HUP} = $refresh;
	$SIG{CHLD} = 'DEFAULT';
	$SIG{$_} = 'IGNORE' for qw(USR2 TTIN TTOU WINCH);
	# this calls epoll_create:
	@listeners = map {
		PublicInbox::Listener->new($_, $post_accept)
	} @listeners;
	PublicInbox::EvCleanup::enable();
	Danga::Socket->EventLoop;
	$parent_pipe = undef;
}


sub run ($$$) {
	my ($default, $refresh, $post_accept) = @_;
	daemon_prepare($default);
	daemonize();
	daemon_loop($refresh, $post_accept);
}

sub do_chown ($) {
	my ($path) = @_;
	if (defined $uid and !chown($uid, $gid, $path)) {
		warn "could not chown $path: $!\n";
	}
}

sub write_pid ($) {
	my ($path) = @_;
	Net::Server::Daemonize::create_pid_file($path);
	do_chown($path);
}

1;
