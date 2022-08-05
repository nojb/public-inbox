# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Contains common daemon code for the httpd, imapd, and nntpd servers
# and designed for handling thousands of untrusted clients over slow
# and/or lossy connections.
package PublicInbox::Daemon;
use strict;
use v5.10.1;
use Getopt::Long qw(:config gnu_getopt no_ignore_case auto_abbrev);
use IO::Handle; # ->autoflush
use IO::Socket;
use File::Spec;
use POSIX qw(WNOHANG :signal_h);
use Socket qw(IPPROTO_TCP SOL_SOCKET);
STDOUT->autoflush(1);
STDERR->autoflush(1);
use PublicInbox::DS qw(now);
use PublicInbox::Listener;
use PublicInbox::EOFpipe;
use PublicInbox::Sigfd;
use PublicInbox::Git;
use PublicInbox::GitAsyncCat;
use PublicInbox::Eml;
use PublicInbox::Config;
our $SO_ACCEPTFILTER = 0x1000;
my @CMD;
my ($set_user, $oldset);
my (@cfg_listen, $stdout, $stderr, $group, $user, $pid_file, $daemonize);
my $worker_processes = 1;
my @listeners;
my (%pids, %logs);
my %tls_opt; # scheme://sockname => args for IO::Socket::SSL::SSL_Context->new
my $reexec_pid;
my ($uid, $gid);
my ($default_cert, $default_key);
my %KNOWN_TLS = (443 => 'https', 563 => 'nntps', 993 => 'imaps', 995 =>'pop3s');
my %KNOWN_STARTTLS = (110 => 'pop3', 119 => 'nntp', 143 => 'imap');
my %SCHEME2PORT = map { $KNOWN_TLS{$_} => $_ + 0 } keys %KNOWN_TLS;
for (keys %KNOWN_STARTTLS) { $SCHEME2PORT{$KNOWN_STARTTLS{$_}} = $_ + 0 }
$SCHEME2PORT{http} = 80;

sub listener_opt ($) {
	my ($str) = @_; # opt1=val1,opt2=val2 (opt may repeat for multi-value)
	my $o = {};
	# allow ',' as delimiter since '&' is shell-unfriendly
	for (split(/[,&]/, $str)) {
		my ($k, $v) = split(/=/, $_, 2);
		push @{$o->{$k}}, $v;
	}

	# key may be a part of cert.  At least
	# p5-io-socket-ssl/example/ssl_server.pl has this fallback:
	$o->{cert} //= [ $default_cert ] if defined($default_cert);
	$o->{key} //= defined($default_key) ? [ $default_key ] : $o->{cert};
	$o;
}

sub check_absolute ($$) {
	my ($var, $val) = @_;
	die <<EOM if index($val // '/', '/') != 0;
$var must be an absolute path when using --daemonize: $val
EOM
}

sub accept_tls_opt ($) {
	my ($opt) = @_;
	my $o = ref($opt) eq 'HASH' ? $opt : listener_opt($opt);
	return if !defined($o->{cert});
	require PublicInbox::TLS;
	my @ctx_opt;
	# parse out hostname:/path/to/ mappings:
	for my $k (qw(cert key)) {
		$o->{$k} // next;
		push(@ctx_opt, "SSL_${k}_file", {});
		foreach my $path (@{$o->{$k}}) {
			my $host = '';
			$path =~ s/\A([^:]+):// and $host = $1;
			$ctx_opt[-1]->{$host} = $path;
			check_absolute($k, $path) if $daemonize;
		}
	}
	\@ctx_opt;
}

sub do_chown ($) {
	$uid // return;
	my ($path) = @_;
	chown($uid, $gid, $path) or warn "chown $path: $!\n";
}

sub open_log_path ($$) { # my ($fh, $path) = @_; # $_[0] is modified
	open $_[0], '>>', $_[1] or die "open(>> $_[1]): $!";
	$_[0]->autoflush(1);
	do_chown($_[1]);
	$_[0];
}

sub load_mod ($;$$) {
	my ($scheme, $opt, $addr) = @_;
	my $modc = "PublicInbox::\U$scheme";
	$modc =~ s/S\z//;
	my $mod = $modc.'D';
	eval "require $mod"; # IMAPD|HTTPD|NNTPD|POP3D
	die $@ if $@;
	my %xn;
	my $tlsd = $xn{tlsd} = $mod->new;
	my %env = map {
		substr($_, length('env.')) => $opt->{$_}->[-1];
	} grep(/\Aenv\./, keys %$opt);
	$xn{refresh} = sub {
		my ($sig) = @_;
		local @ENV{keys %env} = values %env;
		$tlsd->refresh_groups($sig);
	};
	$xn{post_accept} = $tlsd->can('post_accept_cb') ?
			$tlsd->post_accept_cb : sub { $modc->new($_[0], $tlsd) };
	my @paths = qw(out err);
	if ($modc eq 'PublicInbox::HTTP') {
		@paths = qw(err);
		$xn{af_default} = 'httpready';
		if (my $p = $opt->{psgi}) {
			die "multiple psgi= options specified\n" if @$p > 1;
			check_absolute('psgi=', $p->[0]) if $daemonize;
			$tlsd->{psgi} = $p->[0];
			warn "# $scheme://$addr psgi=$p->[0]\n";
		}
	}
	for my $f (@paths) {
		my $p = $opt->{$f} or next;
		die "multiple $f= options specified\n" if @$p > 1;
		check_absolute("$f=", $p->[0]) if $daemonize;
		$p = File::Spec->canonpath($p->[0]);
		$tlsd->{$f} = $logs{$p} //= open_log_path(my $fh, $p);
		warn "# $scheme://$addr $f=$p\n";
	}
	\%xn;
}

sub daemon_prepare ($$) {
	my ($default_listen, $xnetd) = @_;
	my $listener_names = {}; # sockname => IO::Handle
	$oldset = PublicInbox::DS::block_signals();
	@CMD = ($0, @ARGV);
	my ($prog) = ($CMD[0] =~ m!([^/]+)\z!g);
	my $dh = defined($default_listen) ? " (default: $default_listen)" : '';
	my $help = <<EOF;
usage: $prog [-l ADDRESS] [--cert=FILE] [--key=FILE]

options:

  -l ADDRESS    address to listen on$dh
  --cert=FILE   default SSL/TLS certificate
  --key=FILE    default SSL/TLS certificate
  -W WORKERS    number of worker processes to spawn (default: 1)

See public-inbox-daemon(8) and $prog(1) man pages for more.
EOF
	my %opt = (
		'l|listen=s' => \@cfg_listen,
		'1|stdout=s' => \$stdout,
		'2|stderr=s' => \$stderr,
		'W|worker-processes=i' => \$worker_processes,
		'P|pid-file=s' => \$pid_file,
		'u|user=s' => \$user,
		'g|group=s' => \$group,
		'D|daemonize' => \$daemonize,
		'cert=s' => \$default_cert,
		'key=s' => \$default_key,
		'help|h' => \(my $show_help),
	);
	GetOptions(%opt) or die $help;
	if ($show_help) { print $help; exit 0 };

	$_ = File::Spec->canonpath($_ // next) for ($stdout, $stderr);
	if (defined $pid_file && $pid_file =~ /\.oldbin\z/) {
		die "--pid-file cannot end with '.oldbin'\n";
	}
	@listeners = inherit($listener_names);

	# allow socket-activation users to set certs once and not
	# have to configure each socket:
	my @inherited_names = keys(%$listener_names) if defined($default_cert);

	# ignore daemonize when inheriting
	$daemonize = undef if scalar @listeners;

	unless (@listeners || @cfg_listen) {
		$default_listen // die "no listeners specified\n";
		push @cfg_listen, $default_listen
	}

	foreach my $l (@cfg_listen) {
		my $orig = $l;
		my $scheme = '';
		my $port;
		if ($l =~ s!\A([^:]+)://!!) { $scheme = $1 }
		if ($l =~ /\A(?:\[[^\]]+\]|[^:]+):([0-9]+)/) {
			$port = $1 + 0;
			my $s = $KNOWN_TLS{$port} // $KNOWN_STARTTLS{$port};
			$scheme //= $s if defined $s;
		} elsif (index($l, '/') != 0) { # unix socket
			$port //= $SCHEME2PORT{$scheme} if $scheme;
			$port // die "no port in listen=$l\n";
			$l =~ s!\A([^/]+)!$1:$port! or
				die "unable to add port=$port to $l\n";
		}
		my $opt; # non-TLS options
		if ($l =~ s!/?\?(.+)\z!!) {
			$opt = listener_opt($1);
			$tls_opt{"$scheme://$l"} = accept_tls_opt($opt);
		} elsif (defined($default_cert)) {
			$tls_opt{"$scheme://$l"} = accept_tls_opt('');
		} elsif ($scheme =~ /\A(?:https|imaps|nntps|pop3s)\z/) {
			die "$orig specified w/o cert=\n";
		}
		$scheme =~ /\A(?:http|imap|nntp|pop3)/ and
			$xnetd->{$l} = load_mod($scheme, $opt, $l);

		next if $listener_names->{$l}; # already inherited
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
			$s->blocking(0);
			my $k = sockname($s);
			warn "# bound $scheme://$k\n";
			$listener_names->{$k} = $s;
			push @listeners, $s;
		}
	}

	# cert/key options in @cfg_listen takes precedence when inheriting,
	# but map well-known inherited ports if --listen isn't specified
	# at all
	for my $sockname (@inherited_names) {
		$sockname =~ /:([0-9]+)\z/ or next;
		if (my $scheme = $KNOWN_TLS{$1}) {
			$xnetd->{$sockname} //= load_mod($scheme);
			$tls_opt{"$scheme://$sockname"} ||= accept_tls_opt('');
		} elsif (($scheme = $KNOWN_STARTTLS{$1})) {
			$xnetd->{$sockname} //= load_mod($scheme);
			$tls_opt{"$scheme://$sockname"} ||= accept_tls_opt('');
			$tls_opt{''} ||= accept_tls_opt('');
		}
	}
	my @d;
	while (my ($k, $v) = each %tls_opt) { push(@d, $k) if !defined($v) }
	delete @tls_opt{@d};
	die "No listeners bound\n" unless @listeners;
}

sub daemonize () {
	if ($daemonize) {
		require Cwd;
		foreach my $i (0..$#ARGV) {
			my $arg = $ARGV[$i];
			next unless -e $arg;
			$ARGV[$i] = Cwd::abs_path($arg);
		}
		check_absolute('--stdout', $stdout);
		check_absolute('--stderr', $stderr);
		check_absolute('--pid-file', $pid_file);
		check_absolute('--cert', $default_cert);
		check_absolute('--key', $default_key);

		chdir '/' or die "chdir failed: $!";
	}
	if (defined($pid_file) || defined($group) || defined($user)) {
		eval { require Net::Server::Daemonize; 1 } // die <<EOF;
Net::Server required for --pid-file, --group, --user
$@
EOF
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
		my $pid = fork // die "fork: $!";
		exit if $pid;

		open(STDIN, '+<', '/dev/null') or
					die "redirect stdin failed: $!\n";
		open STDOUT, '>&STDIN' or die "redirect stdout failed: $!\n";
		open STDERR, '>&STDIN' or die "redirect stderr failed: $!\n";
		POSIX::setsid();
		$pid = fork // die "fork: $!";
		exit if $pid;
	}
	return unless defined $pid_file;

	write_pid($pid_file);
	# for ->DESTROY:
	bless { pid => $$, pid_file => \$pid_file }, __PACKAGE__;
}

sub worker_quit { # $_[0] = signal name or number (unused)
	# killing again terminates immediately:
	exit unless @listeners;

	$_->close foreach @listeners; # call PublicInbox::DS::close
	@listeners = ();
	my $proc_name;
	my $warn = 0;
	# drop idle connections and try to quit gracefully
	PublicInbox::DS->SetPostLoopCallback(sub {
		my ($dmap, undef) = @_;
		my $n = 0;
		my $now = now();
		for my $s (values %$dmap) {
			$s->can('busy') or next;
			if ($s->busy) {
				++$n;
			} else { # close as much as possible, early as possible
				$s->close;
			}
		}
		if ($n) {
			if (($warn + 5) < now()) {
				warn "$$ quitting, $n client(s) left\n";
				$warn = now();
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
	$logs{$stdout} //= \*STDOUT if defined $stdout;
	$logs{$stderr} //= \*STDERR if defined $stderr;
	while (my ($p, $fh) = each %logs) { open_log_path($fh, $p) }
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

sub unpack_ipv6 ($) {
	my ($addr) = @_;
	my ($port, $host);

	# Socket.pm in Perl 5.14+ supports IPv6:
	eval {
		($port, $host) = Socket::unpack_sockaddr_in6($addr);
		$host = Socket::inet_ntop(Socket::AF_INET6(), $host);
	};

	if ($@) {
		# Perl 5.12 or earlier?  SpamAssassin and Net::Server use
		# Socket6, so it may be installed on our system, already
		# (otherwise die here):
		require Socket6;

		($port, $host) = Socket6::unpack_sockaddr_in6($addr);
		$host = Socket6::inet_ntop(Socket6::AF_INET6(), $host);
	}
	($host, $port);
}

sub host_with_port ($) {
	my ($addr) = @_;
	my ($port, $host);

	# this eval will die on Unix sockets:
	eval {
		if (length($addr) >= 28) {
			($host, $port) = unpack_ipv6($addr);
			$host = "[$host]";
		} else {
			($port, $host) = Socket::sockaddr_in($addr);
			$host = Socket::inet_ntoa($host);
		}
	};
	$@ ? ('127.0.0.1', 0) : ($host, $port);
}

sub inherit ($) {
	my ($listener_names) = @_;
	return () if ($ENV{LISTEN_PID} || 0) != $$;
	my $fds = $ENV{LISTEN_FDS} or return ();
	my $end = $fds + 2; # LISTEN_FDS_START - 1
	my @rv = ();
	foreach my $fd (3..$end) {
		open(my $s, '<&=', $fd) or warn "fdopen fd=$fd: $!";
		if (my $k = sockname($s)) {
			my $prev_was_blocking = $s->blocking(0);
			warn <<"" if $prev_was_blocking;
Inherited socket ($k fd=$fd) is blocking, making it non-blocking.
Set 'NonBlocking = true' in the systemd.service unit to avoid stalled
processes when multiple service instances start.

			$listener_names->{$k} = $s;
			warn "# inherited $k fd=$fd\n";
			push @rv, $s;
		} else {
			warn "failed to inherit fd=$fd (LISTEN_FDS=$fds)";
		}
	}
	@rv
}

sub upgrade { # $_[0] = signal name or number (unused)
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
			# @listeners are globs with workers, PI::L w/o workers
			$s = $s->{sock} if ref($s) eq 'PublicInbox::Listener';

			my $fl = fcntl($s, F_GETFD, 0);
			fcntl($s, F_SETFD, $fl &= ~FD_CLOEXEC);
		}
		exec @CMD;
		die "Failed to exec: $!\n";
	}
	$reexec_pid = $pid;
}

sub kill_workers ($) {
	my ($sig) = @_;
	kill $sig, keys(%pids);
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

sub reap_children { # $_[0] = 'CHLD' or POSIX::SIGCHLD()
	while (1) {
		my $p = waitpid(-1, WNOHANG) or return;
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

sub master_quit ($) {
	exit unless @listeners;
	@listeners = ();
	kill_workers($_[0]);
}

sub master_loop {
	pipe(my ($p0, $p1)) or die "failed to create parent-pipe: $!";
	my $set_workers = $worker_processes;
	reopen_logs();
	my $ignore_winch;
	my $sig = {
		USR1 => sub { reopen_logs(); kill_workers($_[0]); },
		USR2 => \&upgrade,
		QUIT => \&master_quit,
		INT => \&master_quit,
		TERM => \&master_quit,
		WINCH => sub {
			return if $ignore_winch || !@listeners;
			if (-t STDIN || -t STDOUT || -t STDERR) {
				$ignore_winch = 1;
				warn <<EOF;
ignoring SIGWINCH since we are not daemonized
EOF
			} else {
				$worker_processes = 0;
			}
		},
		HUP => sub {
			return unless @listeners;
			$worker_processes = $set_workers;
			kill_workers($_[0]);
		},
		TTIN => sub {
			return unless @listeners;
			if ($set_workers > $worker_processes) {
				++$worker_processes;
			} else {
				$worker_processes = ++$set_workers;
			}
		},
		TTOU => sub {
			$worker_processes = --$set_workers if $set_workers > 0;
		},
		CHLD => \&reap_children,
	};
	my $sigfd = PublicInbox::Sigfd->new($sig);
	local @SIG{keys %$sig} = values(%$sig) unless $sigfd;
	PublicInbox::DS::sig_setmask($oldset) if !$sigfd;
	while (1) { # main loop
		my $n = scalar keys %pids;
		unless (@listeners) {
			exit if $n == 0;
			$set_workers = $worker_processes = $n = 0;
		}

		if ($n > $worker_processes) {
			while (my ($k, $v) = each %pids) {
				kill('TERM', $k) if $v >= $worker_processes;
			}
			$n = $worker_processes;
		}
		my $want = $worker_processes - 1;
		if ($n <= $want) {
			PublicInbox::DS::block_signals() if !$sigfd;
			for my $i ($n..$want) {
				my $seed = rand(0xffffffff);
				my $pid = fork;
				if (!defined $pid) {
					warn "failed to fork worker[$i]: $!\n";
				} elsif ($pid == 0) {
					srand($seed);
					eval { Net::SSLeay::randomize() };
					$set_user->() if $set_user;
					return $p0; # run normal work code
				} else {
					warn "PID=$pid is worker[$i]\n";
					$pids{$pid} = $i;
				}
			}
			PublicInbox::DS::sig_setmask($oldset) if !$sigfd;
		}

		if ($sigfd) { # Linux and IO::KQueue users:
			$sigfd->wait_once;
		} else { # wake up every second
			sleep(1);
		}
	}
	exit # never gets here, just for documentation
}

sub tls_cb {
	my ($post_accept, $tlsd) = @_;
	sub {
		my ($io, $addr, $srv) = @_;
		$post_accept->(PublicInbox::TLS::start($io, $tlsd), $addr, $srv)
	}
}

sub defer_accept ($$) {
	my ($s, $af_name) = @_;
	return unless defined $af_name;
	if ($^O eq 'linux') {
		my $TCP_DEFER_ACCEPT = 9; # Socket::TCP_DEFER_ACCEPT is in 5.14+
		my $x = getsockopt($s, IPPROTO_TCP, $TCP_DEFER_ACCEPT);
		return unless defined $x; # may be Unix socket
		my $sec = unpack('i', $x);
		return if $sec > 0; # systemd users may set a higher value
		setsockopt($s, IPPROTO_TCP, $TCP_DEFER_ACCEPT, 1);
	} elsif ($^O eq 'freebsd') {
		my $x = getsockopt($s, SOL_SOCKET, $SO_ACCEPTFILTER);
		return if defined $x; # don't change if set
		my $accf_arg = pack('a16a240', $af_name, '');
		setsockopt($s, SOL_SOCKET, $SO_ACCEPTFILTER, $accf_arg);
	}
}

sub daemon_loop ($) {
	my ($xnetd) = @_;
	local $PublicInbox::Config::DEDUPE = {}; # enable dedupe cache
	my $refresh = sub {
		my ($sig) = @_;
		%$PublicInbox::Config::DEDUPE = (); # clear cache
		for my $xn (values %$xnetd) {
			delete $xn->{tlsd}->{ssl_ctx}; # PublicInbox::TLS::start
			eval { $xn->{refresh}->($sig) };
			warn "refresh $@\n" if $@;
		}
	};
	my %post_accept;
	while (my ($k, $ctx_opt) = each %tls_opt) {
		my $l = $k;
		$l =~ s!\A([^:]+)://!!;
		my $scheme = $1 // '';
		my $xn = $xnetd->{$l} // $xnetd->{''};
		$xn->{tlsd}->{ssl_ctx_opt} //= $ctx_opt;
		$scheme =~ m!\A(?:https|imaps|nntps|pop3s)! and
			$post_accept{$l} = tls_cb(@$xn{qw(post_accept tlsd)});
	}
	my $sig = {
		HUP => $refresh,
		INT => \&worker_quit,
		QUIT => \&worker_quit,
		TERM => \&worker_quit,
		TTIN => 'IGNORE',
		TTOU => 'IGNORE',
		USR1 => \&reopen_logs,
		USR2 => 'IGNORE',
		WINCH => 'IGNORE',
		CHLD => \&PublicInbox::DS::enqueue_reap,
	};
	if ($worker_processes > 0) {
		$refresh->(); # preload by default
		my $fh = master_loop(); # returns if in child process
		PublicInbox::EOFpipe->new($fh, \&worker_quit, undef);
	} else {
		reopen_logs();
		$set_user->() if $set_user;
		$sig->{USR2} = sub { worker_quit() if upgrade() };
		$refresh->();
	}
	$uid = $gid = undef;
	reopen_logs();
	@listeners = map {;
		my $l = sockname($_);
		my $tls_cb = $post_accept{$l};
		my $xn = $xnetd->{$l} // $xnetd->{''};

		# NNTPS, HTTPS, HTTP, IMAPS and POP3S are client-first traffic
		# IMAP, NNTP and POP3 are server-first
		defer_accept($_, $tls_cb ? 'dataready' : $xn->{af_default});

		# this calls epoll_create:
		PublicInbox::Listener->new($_, $tls_cb || $xn->{post_accept})
	} @listeners;
	PublicInbox::DS::event_loop($sig, $oldset);
}

sub run {
	my ($default_listen) = @_;
	my $xnetd = {};
	if ($default_listen) {
		$default_listen =~ /\A(http|imap|nntp|pop3)/ or
			die "BUG: $default_listen";
		$xnetd->{''} = load_mod($1);
	}
	daemon_prepare($default_listen, $xnetd);
	my $for_destroy = daemonize();

	# localize GCF2C for tests:
	local $PublicInbox::GitAsyncCat::GCF2C;
	local $PublicInbox::Git::async_warn = 1;
	local $SIG{__WARN__} = PublicInbox::Eml::warn_ignore_cb();

	daemon_loop($xnetd);
	PublicInbox::DS->Reset;
	# ->DESTROY runs when $for_destroy goes out-of-scope
}

sub write_pid ($) {
	my ($path) = @_;
	Net::Server::Daemonize::create_pid_file($path);
	do_chown($path);
}

sub DESTROY {
	unlink_pid_file_safe_ish($_[0]->{pid}, ${$_[0]->{pid_file}});
}

1;
