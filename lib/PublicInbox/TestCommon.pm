# Copyright (C) 2015-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# internal APIs used only for tests
package PublicInbox::TestCommon;
use strict;
use parent qw(Exporter);
use v5.10.1;
use Fcntl qw(FD_CLOEXEC F_SETFD F_GETFD :seek);
use POSIX qw(dup2);
use IO::Socket::INET;
use File::Spec;
our @EXPORT;
my $lei_loud = $ENV{TEST_LEI_ERR_LOUD};
my $tail_cmd = $ENV{TAIL};
our ($lei_opt, $lei_out, $lei_err, $lei_cwdfh);
BEGIN {
	@EXPORT = qw(tmpdir tcp_server tcp_connect require_git require_mods
		run_script start_script key2sub xsys xsys_e xqx eml_load tick
		have_xapian_compact json_utf8 setup_public_inboxes create_inbox
		tcp_host_port test_lei lei lei_ok $lei_out $lei_err $lei_opt
		test_httpd xbail require_cmd is_xdeeply tail_f);
	require Test::More;
	my @methods = grep(!/\W/, @Test::More::EXPORT);
	eval(join('', map { "*$_=\\&Test::More::$_;" } @methods));
	die $@ if $@;
	push @EXPORT, @methods;
}

sub xbail (@) { BAIL_OUT join(' ', map { ref() ? (explain($_)) : ($_) } @_) }

sub eml_load ($) {
	my ($path, $cb) = @_;
	open(my $fh, '<', $path) or die "open $path: $!";
	require PublicInbox::Eml;
	PublicInbox::Eml->new(\(do { local $/; <$fh> }));
}

sub tmpdir (;$) {
	my ($base) = @_;
	require File::Temp;
	unless (defined $base) {
		($base) = ($0 =~ m!\b([^/]+)\.[^\.]+\z!);
	}
	my $tmpdir = File::Temp->newdir("pi-$base-$$-XXXX", TMPDIR => 1);
	($tmpdir->dirname, $tmpdir);
}

sub tcp_server () {
	my %opt = (
		ReuseAddr => 1,
		Proto => 'tcp',
		Type => Socket::SOCK_STREAM(),
		Listen => 1024,
		Blocking => 0,
	);
	eval {
		die 'IPv4-only' if $ENV{TEST_IPV4_ONLY};
		require IO::Socket::INET6;
		IO::Socket::INET6->new(%opt, LocalAddr => '[::1]')
	} || eval {
		die 'IPv6-only' if $ENV{TEST_IPV6_ONLY};
		IO::Socket::INET->new(%opt, LocalAddr => '127.0.0.1')
	} || BAIL_OUT "failed to create TCP server: $! ($@)";
}

sub tcp_host_port ($) {
	my ($s) = @_;
	my ($h, $p) = ($s->sockhost, $s->sockport);
	my $ipv4 = $s->sockdomain == Socket::AF_INET();
	if (wantarray) {
		$ipv4 ? ($h, $p) : ("[$h]", $p);
	} else {
		$ipv4 ? "$h:$p" : "[$h]:$p";
	}
}

sub tcp_connect {
	my ($dest, %opt) = @_;
	my $addr = tcp_host_port($dest);
	my $s = ref($dest)->new(
		Proto => 'tcp',
		Type => Socket::SOCK_STREAM(),
		PeerAddr => $addr,
		%opt,
	) or BAIL_OUT "failed to connect to $addr: $!";
	$s->autoflush(1);
	$s;
}

sub require_cmd ($;$) {
	my ($cmd, $maybe) = @_;
	require PublicInbox::Spawn;
	my $bin = PublicInbox::Spawn::which($cmd);
	return $bin if $bin;
	$maybe ? 0 : plan(skip_all => "$cmd missing from PATH for $0");
}

sub have_xapian_compact () {
	require_cmd($ENV{XAPIAN_COMPACT} || 'xapian-compact', 1);
}

sub require_git ($;$) {
	my ($req, $maybe) = @_;
	my ($req_maj, $req_min, $req_sub) = split(/\./, $req);
	my ($cur_maj, $cur_min, $cur_sub) = (xqx([qw(git --version)])
			=~ /version (\d+)\.(\d+)(?:\.(\d+))?/);

	my $req_int = ($req_maj << 24) | ($req_min << 16) | ($req_sub // 0);
	my $cur_int = ($cur_maj << 24) | ($cur_min << 16) | ($cur_sub // 0);
	if ($cur_int < $req_int) {
		return 0 if $maybe;
		plan skip_all =>
			"git $req+ required, have $cur_maj.$cur_min.$cur_sub";
	}
	1;
}

sub require_mods {
	my @mods = @_;
	my $maybe = pop @mods if $mods[-1] =~ /\A[0-9]+\z/;
	my @need;
	while (my $mod = shift(@mods)) {
		if ($mod eq 'lei') {
			require_git(2.6, $maybe ? $maybe : ());
			push @mods, qw(DBD::SQLite Search::Xapian);
			$mod = 'json'; # fall-through
		}
		if ($mod eq 'json') {
			$mod = 'Cpanel::JSON::XS||JSON::MaybeXS||JSON||JSON::PP'
		} elsif ($mod eq '-httpd') {
			push @mods, qw(Plack::Builder Plack::Util);
			next;
		} elsif ($mod eq '-imapd') {
			push @mods, qw(Parse::RecDescent DBD::SQLite
					Email::Address::XS||Mail::Address);
			next;
		} elsif ($mod eq '-nntpd') {
			push @mods, qw(DBD::SQLite);
			next;
		}
		if ($mod eq 'Search::Xapian') {
			if (eval { require PublicInbox::Search } &&
				PublicInbox::Search::load_xapian()) {
				next;
			}
		} elsif (index($mod, '||') >= 0) { # "Foo||Bar"
			my $ok;
			for my $m (split(/\Q||\E/, $mod)) {
				eval "require $m";
				next if $@;
				$ok = $m;
				last;
			}
			next if $ok;
		} else {
			eval "require $mod";
		}
		if ($@) {
			diag "require $mod: $@" if $mod =~ /Gcf2/;
			push @need, $mod;
		} elsif ($mod eq 'IO::Socket::SSL' &&
			# old versions of IO::Socket::SSL aren't supported
			# by libnet, at least:
			# https://rt.cpan.org/Ticket/Display.html?id=100529
				!eval{ IO::Socket::SSL->VERSION(2.007); 1 }) {
			push @need, $@;
		}
	}
	return unless @need;
	my $m = join(', ', @need)." missing for $0";
	skip($m, $maybe) if $maybe;
	plan(skip_all => $m)
}

sub key2script ($) {
	my ($key) = @_;
	return $key if ($key eq 'git' || index($key, '/') >= 0);
	# n.b. we may have scripts which don't start with "public-inbox" in
	# the future:
	$key =~ s/\A([-\.])/public-inbox$1/;
	'blib/script/'.$key;
}

my @io_mode = ([ *STDIN{IO}, '+<&' ], [ *STDOUT{IO}, '+>&' ],
		[ *STDERR{IO}, '+>&' ]);

sub _prepare_redirects ($) {
	my ($fhref) = @_;
	my $orig_io = [];
	for (my $fd = 0; $fd <= $#io_mode; $fd++) {
		my $fh = $fhref->[$fd] or next;
		my ($oldfh, $mode) = @{$io_mode[$fd]};
		open my $orig, $mode, $oldfh or die "$oldfh $mode stash: $!";
		$orig_io->[$fd] = $orig;
		open $oldfh, $mode, $fh or die "$oldfh $mode redirect: $!";
	}
	$orig_io;
}

sub _undo_redirects ($) {
	my ($orig_io) = @_;
	for (my $fd = 0; $fd <= $#io_mode; $fd++) {
		my $fh = $orig_io->[$fd] or next;
		my ($oldfh, $mode) = @{$io_mode[$fd]};
		open $oldfh, $mode, $fh or die "$$oldfh $mode redirect: $!";
	}
}

# $opt->{run_mode} (or $ENV{TEST_RUN_MODE}) allows choosing between
# three ways to spawn our own short-lived Perl scripts for testing:
#
# 0 - (fork|vfork) + execve, the most realistic but slowest
# 1 - (not currently implemented)
# 2 - preloading and running in current process (slightly faster than 1)
#
# 2 is not compatible with scripts which use "exit" (which we'll try to
# avoid in the future).
# The default is 2.
our $run_script_exit_code;
sub RUN_SCRIPT_EXIT () { "RUN_SCRIPT_EXIT\n" };
sub run_script_exit {
	$run_script_exit_code = $_[0] // 0;
	die RUN_SCRIPT_EXIT;
}

our %cached_scripts;
sub key2sub ($) {
	my ($key) = @_;
	$cached_scripts{$key} //= do {
		my $f = key2script($key);
		open my $fh, '<', $f or die "open $f: $!";
		my $str = do { local $/; <$fh> };
		my $pkg = (split(m!/!, $f))[-1];
		$pkg =~ s/([a-z])([a-z0-9]+)(\.t)?\z/\U$1\E$2/;
		$pkg .= "_T" if $3;
		$pkg =~ tr/-.//d;
		$pkg = "PublicInbox::TestScript::$pkg";
		eval <<EOF;
package $pkg;
use strict;
use subs qw(exit);

*exit = \\&PublicInbox::TestCommon::run_script_exit;
sub main {
# the below "line" directive is a magic comment, see perlsyn(1) manpage
# line 1 "$f"
$str
	0;
}
1;
EOF
		$pkg->can('main');
	}
}

sub _run_sub ($$$) {
	my ($sub, $key, $argv) = @_;
	local @ARGV = @$argv;
	$run_script_exit_code = undef;
	my $exit_code = eval { $sub->(@$argv) };
	if ($@ eq RUN_SCRIPT_EXIT) {
		$@ = '';
		$exit_code = $run_script_exit_code;
		$? = ($exit_code << 8);
	} elsif (defined($exit_code)) {
		$? = ($exit_code << 8);
	} elsif ($@) { # mimic die() behavior when uncaught
		warn "E: eval-ed $key: $@\n";
		$? = ($! << 8) if $!;
		$? = (255 << 8) if $? == 0;
	} else {
		die "BUG: eval-ed $key: no exit code or \$@\n";
	}
}

sub run_script ($;$$) {
	my ($cmd, $env, $opt) = @_;
	my ($key, @argv) = @$cmd;
	my $run_mode = $ENV{TEST_RUN_MODE} // $opt->{run_mode} // 1;
	my $sub = $run_mode == 0 ? undef : key2sub($key);
	my $fhref = [];
	my $spawn_opt = {};
	my @tail_paths;
	for my $fd (0..2) {
		my $redir = $opt->{$fd};
		my $ref = ref($redir);
		if ($ref eq 'SCALAR') {
			my $fh;
			if ($tail_cmd && $ENV{TAIL_ALL} && $fd > 0) {
				require File::Temp;
				$fh = File::Temp->new("fd.$fd-XXXX", TMPDIR=>1);
				push @tail_paths, $fh->filename;
			} else {
				open $fh, '+>', undef;
			}
			$fh or xbail $!;
			$fhref->[$fd] = $fh;
			$spawn_opt->{$fd} = $fh;
			next if $fd > 0;
			$fh->autoflush(1);
			print $fh $$redir or die "print: $!";
			seek($fh, 0, SEEK_SET) or die "seek: $!";
		} elsif ($ref eq 'GLOB') {
			$spawn_opt->{$fd} = $fhref->[$fd] = $redir;
		} elsif ($ref) {
			die "unable to deal with $ref $redir";
		}
	}
	my $tail = @tail_paths ? tail_f(@tail_paths) : undef;
	if ($key =~ /-(index|convert|extindex|convert|xcpdb)\z/) {
		unshift @argv, '--no-fsync';
	}
	if ($run_mode == 0) {
		# spawn an independent new process, like real-world use cases:
		require PublicInbox::Spawn;
		my $cmd = [ key2script($key), @argv ];
		if (my $d = $opt->{'-C'}) {
			$cmd->[0] = File::Spec->rel2abs($cmd->[0]);
			$spawn_opt->{'-C'} = $d;
		}
		my $pid = PublicInbox::Spawn::spawn($cmd, $env, $spawn_opt);
		if (defined $pid) {
			my $r = waitpid($pid, 0) // die "waitpid: $!";
			$r == $pid or die "waitpid: expected $pid, got $r";
		}
	} else { # localize and run everything in the same process:
		# note: "local *STDIN = *STDIN;" and so forth did not work in
		# old versions of perl
		my $umask = umask;
		local %ENV = $env ? (%ENV, %$env) : %ENV;
		local @SIG{keys %SIG} = map { undef } values %SIG;
		local $SIG{FPE} = 'IGNORE'; # Perl default
		local $0 = join(' ', @$cmd);
		my $orig_io = _prepare_redirects($fhref);
		my $cwdfh = $lei_cwdfh;
		if (my $d = $opt->{'-C'}) {
			unless ($cwdfh) {
				opendir $cwdfh, '.' or die "opendir .: $!";
			}
			chdir $d or die "chdir $d: $!";
		}
		_run_sub($sub, $key, \@argv);
		eval { PublicInbox::Inbox::cleanup_task() };
		die "fchdir(restore): $!" if $cwdfh && !chdir($cwdfh);
		_undo_redirects($orig_io);
		select STDOUT;
		umask($umask);
	}

	{ local $?; undef $tail };
	# slurp the redirects back into user-supplied strings
	for my $fd (1..2) {
		my $fh = $fhref->[$fd] or next;
		next unless -f $fh;
		seek($fh, 0, SEEK_SET) or die "seek: $!";
		my $redir = $opt->{$fd};
		local $/;
		$$redir = <$fh>;
	}
	$? == 0;
}

sub tick (;$) {
	my $tick = shift // 0.1;
	select undef, undef, undef, $tick;
	1;
}

sub wait_for_tail {
	my ($tail_pid, $want) = @_;
	my $wait = 2; # "tail -F" sleeps 1.0s at-a-time w/o inotify/kevent
	if ($^O eq 'linux') { # GNU tail may use inotify
		state $tail_has_inotify;
		return tick if !$want && $tail_has_inotify; # before TERM
		my $end = time + $wait; # wait for startup:
		my @ino;
		do {
			@ino = grep {
				readlink($_) =~ /\binotify\b/
			} glob("/proc/$tail_pid/fd/*");
		} while (!@ino && time <= $end and tick);
		return if !@ino;
		$tail_has_inotify = 1;
		$ino[0] =~ s!/fd/!/fdinfo/!;
		my @info;
		do {
			if (open my $fh, '<', $ino[0]) {
				local $/ = "\n";
				@info = grep(/^inotify wd:/, <$fh>);
			}
		} while (scalar(@info) < $want && time <= $end and tick);
	} else {
		sleep($wait);
	}
}

# like system() built-in, but uses spawn() for env/rdr + vfork
sub xsys {
	my ($cmd, $env, $rdr) = @_;
	if (ref($cmd)) {
		$rdr ||= {};
	} else {
		$cmd = [ @_ ];
		$env = undef;
		$rdr = {};
	}
	run_script($cmd, $env, { %$rdr, run_mode => 0 });
	$? >> 8
}

sub xsys_e { # like "/bin/sh -e"
	xsys(@_) == 0 or
		BAIL_OUT (ref $_[0] ? "@{$_[0]}" : "@_"). " failed \$?=$?"
}

# like `backtick` or qx{} op, but uses spawn() for env/rdr + vfork
sub xqx {
	my ($cmd, $env, $rdr) = @_;
	$rdr //= {};
	run_script($cmd, $env, { %$rdr, run_mode => 0, 1 => \(my $out) });
	wantarray ? split(/^/m, $out) : $out;
}

sub tail_f (@) {
	$tail_cmd or return; # "tail -F" or "tail -f"
	for (@_) { open(my $fh, '>>', $_) or die $! };
	my $cmd = [ split(/ /, $tail_cmd), @_ ];
	require PublicInbox::Spawn;
	my $pid = PublicInbox::Spawn::spawn($cmd, undef, { 1 => 2 });
	wait_for_tail($pid, scalar @_);
	require PublicInbox::AutoReap;
	PublicInbox::AutoReap->new($pid, \&wait_for_tail);
}

sub start_script {
	my ($cmd, $env, $opt) = @_;
	my ($key, @argv) = @$cmd;
	my $run_mode = $ENV{TEST_RUN_MODE} // $opt->{run_mode} // 2;
	my $sub = $run_mode == 0 ? undef : key2sub($key);
	my $tail;
	if ($tail_cmd) {
		my @paths;
		for (@argv) {
			next unless /\A--std(?:err|out)=(.+)\z/;
			push @paths, $1;
		}
		if ($opt) {
			for (1, 2) {
				my $f = $opt->{$_} or next;
				if (!ref($f)) {
					push @paths, $f;
				} elsif (ref($f) eq 'GLOB' && $^O eq 'linux') {
					my $fd = fileno($f);
					my $f = readlink "/proc/$$/fd/$fd";
					push @paths, $f if -e $f;
				}
			}
		}
		$tail = tail_f(@paths);
	}
	my $pid = fork // die "fork: $!\n";
	if ($pid == 0) {
		eval { PublicInbox::DS->Reset };
		# pretend to be systemd (cf. sd_listen_fds(3))
		# 3 == SD_LISTEN_FDS_START
		my $fd;
		for ($fd = 0; 1; $fd++) {
			my $s = $opt->{$fd};
			last if $fd >= 3 && !defined($s);
			next unless $s;
			my $fl = fcntl($s, F_GETFD, 0);
			if (($fl & FD_CLOEXEC) != FD_CLOEXEC) {
				warn "got FD:".fileno($s)." w/o CLOEXEC\n";
			}
			fcntl($s, F_SETFD, $fl &= ~FD_CLOEXEC);
			dup2(fileno($s), $fd) or die "dup2 failed: $!\n";
		}
		%ENV = (%ENV, %$env) if $env;
		my $fds = $fd - 3;
		if ($fds > 0) {
			$ENV{LISTEN_PID} = $$;
			$ENV{LISTEN_FDS} = $fds;
		}
		if ($opt->{-C}) { chdir($opt->{-C}) or die "chdir: $!" }
		$0 = join(' ', @$cmd);
		if ($sub) {
			eval { PublicInbox::DS->Reset };
			_run_sub($sub, $key, \@argv);
			POSIX::_exit($? >> 8);
		} else {
			exec(key2script($key), @argv);
			die "FAIL: ",join(' ', $key, @argv), ": $!\n";
		}
	}
	require PublicInbox::AutoReap;
	my $td = PublicInbox::AutoReap->new($pid);
	$td->{-extra} = $tail;
	$td;
}

# favor lei() or lei_ok() over $lei for new code
sub lei (@) {
	my ($cmd, $env, $xopt) = @_;
	$lei_out = $lei_err = '';
	if (!ref($cmd)) {
		($env, $xopt) = grep { (!defined) || ref } @_;
		$cmd = [ grep { defined && !ref } @_ ];
	}
	my $res = run_script(['lei', @$cmd], $env, $xopt // $lei_opt);
	if ($lei_err ne '') {
		if ($lei_err =~ /Use of uninitialized/ ||
			$lei_err =~ m!\bArgument .*? isn't numeric in !) {
			fail "lei_err=$lei_err";
		} else {
			diag "lei_err=$lei_err" if $lei_loud;
		}
	}
	$res;
};

sub lei_ok (@) {
	state $PWD = $ENV{PWD} // Cwd::getcwd();
	my $msg = ref($_[-1]) eq 'SCALAR' ? pop(@_) : undef;
	my $tmpdir = quotemeta(File::Spec->tmpdir);
	# filter out anything that looks like a path name for consistent logs
	my @msg = ref($_[0]) eq 'ARRAY' ? @{$_[0]} : @_;
	if (!$lei_loud) {
		for (@msg) {
			s!\A([a-z0-9]+://)[^/]+/!$1\$HOST_PORT/!;
			s!$tmpdir\b/(?:[^/]+/)?!\$TMPDIR/!g;
			s!\Q$PWD\E\b!\$PWD!g;
		}
	}
	ok(lei(@_), "lei @msg". ($msg ? " ($$msg)" : '')) or
		diag "\$?=$? err=$lei_err";
}

sub json_utf8 () {
	state $x = ref(PublicInbox::Config->json)->new->utf8->canonical;
}

sub is_xdeeply ($$$) {
	my ($x, $y, $desc) = @_;
	my $ok = is_deeply($x, $y, $desc);
	diag explain([$x, '!=', $y]) if !$ok;
	$ok;
}

sub test_lei {
SKIP: {
	my ($cb) = pop @_;
	my $test_opt = shift // {};
	local $lei_cwdfh;
	opendir $lei_cwdfh, '.' or xbail "opendir .: $!";
	require_git(2.6, 1) or skip('git 2.6+ required for lei test', 2);
	my $mods = $test_opt->{mods} // [ 'lei' ];
	require_mods(@$mods, 2);

	# set PERL_INLINE_DIRECTORY before clobbering XDG_CACHE_HOME
	require PublicInbox::Spawn;
	require PublicInbox::Config;
	require File::Path;

	local %ENV = %ENV;
	delete $ENV{XDG_DATA_HOME};
	delete $ENV{XDG_CONFIG_HOME};
	delete $ENV{XDG_CACHE_HOME};
	$ENV{GIT_COMMITTER_EMAIL} = 'lei@example.com';
	$ENV{GIT_COMMITTER_NAME} = 'lei user';
	my (undef, $fn, $lineno) = caller(0);
	my $t = "$fn:$lineno";
	state $lei_daemon = PublicInbox::Spawn->can('send_cmd4') ||
				eval { require Socket::MsgHdr; 1 };
	unless ($lei_daemon) {
		skip('Inline::C unconfigured/missing '.
'(mkdir -p ~/.cache/public-inbox/inline-c) OR Socket::MsgHdr missing',
			1);
	}
	$lei_opt = { 1 => \$lei_out, 2 => \$lei_err };
	my ($daemon_pid, $for_destroy, $daemon_xrd);
	my $tmpdir = $test_opt->{tmpdir};
	File::Path::mkpath($tmpdir) if (defined $tmpdir && !-d $tmpdir);
	($tmpdir, $for_destroy) = tmpdir unless $tmpdir;
	state $persist_xrd = $ENV{TEST_LEI_DAEMON_PERSIST_DIR};
	SKIP: {
		$ENV{TEST_LEI_ONESHOT} and
			xbail 'TEST_LEI_ONESHOT no longer supported';
		my $home = "$tmpdir/lei-daemon";
		mkdir($home, 0700) or BAIL_OUT "mkdir: $!";
		local $ENV{HOME} = $home;
		my $persist;
		if ($persist_xrd && !$test_opt->{daemon_only}) {
			$persist = $daemon_xrd = $persist_xrd;
		} else {
			$daemon_xrd = "$home/xdg_run";
			mkdir($daemon_xrd, 0700) or BAIL_OUT "mkdir: $!";
		}
		local $ENV{XDG_RUNTIME_DIR} = $daemon_xrd;
		$cb->();
		if ($persist) { # remove before ~/.local gets removed
			File::Path::rmtree([glob("$home/*")]);
			File::Path::rmtree("$home/.config");
		} else {
			lei_ok(qw(daemon-pid), \"daemon-pid after $t");
			chomp($daemon_pid = $lei_out);
			if (!$daemon_pid) {
				fail("daemon not running after $t");
				skip 'daemon died unexpectedly', 2;
			}
			ok(kill(0, $daemon_pid), "daemon running after $t");
			lei_ok(qw(daemon-kill), \"daemon-kill after $t");
		}
	}; # SKIP for lei_daemon
	if ($daemon_pid) {
		for (0..10) {
			kill(0, $daemon_pid) or last;
			tick;
		}
		ok(!kill(0, $daemon_pid), "$t daemon stopped");
		my $f = "$daemon_xrd/lei/errors.log";
		open my $fh, '<', $f or BAIL_OUT "$f: $!";
		my @l = <$fh>;
		is_xdeeply(\@l, [],
			"$t daemon XDG_RUNTIME_DIR/lei/errors.log empty");
	}
}; # SKIP if missing git 2.6+ || Xapian || SQLite || json
} # /test_lei

# returns the pathname to a ~/.public-inbox/config in scalar context,
# ($test_home, $pi_config_pathname) in list context
sub setup_public_inboxes () {
	my $test_home = "t/home2";
	my $pi_config = "$test_home/.public-inbox/config";
	my $stamp = "$test_home/setup-stamp";
	my @ret = ($test_home, $pi_config);
	return @ret if -f $stamp;

	require PublicInbox::Lock;
	my $lk = bless { lock_path => "$test_home/setup.lock" },
			'PublicInbox::Lock';
	my $end = $lk->lock_for_scope;
	return @ret if -f $stamp;

	local $ENV{PI_CONFIG} = $pi_config;
	for my $V (1, 2) {
		run_script([qw(-init --skip-docdata), "-V$V",
				'--newsgroup', "t.v$V", "t$V",
				"$test_home/t$V", "http://example.com/t$V",
				"t$V\@example.com" ]) or xbail "init v$V";
		unlink "$test_home/t$V/description" or xbail "unlink $!";
	}
	require PublicInbox::Config;
	require PublicInbox::InboxWritable;
	my $cfg = PublicInbox::Config->new;
	my $seen = 0;
	$cfg->each_inbox(sub {
		my ($ibx) = @_;
		$ibx->{-no_fsync} = 1;
		my $im = PublicInbox::InboxWritable->new($ibx)->importer(0);
		my $V = $ibx->version;
		my @eml = (glob('t/*.eml'), 't/data/0001.patch');
		for (@eml) {
			next if $_ eq 't/psgi_v2-old.eml'; # dup mid
			$im->add(eml_load($_)) or BAIL_OUT "v$V add $_";
			$seen++;
		}
		$im->done;
	});
	$seen or BAIL_OUT 'no imports';
	open my $fh, '>', $stamp or BAIL_OUT "open $stamp: $!";
	@ret;
}

sub create_inbox ($$;@) {
	my $ident = shift;
	my $cb = pop;
	my %opt = @_;
	require PublicInbox::Lock;
	require PublicInbox::InboxWritable;
	require PublicInbox::Import;
	my ($base) = ($0 =~ m!\b([^/]+)\.[^\.]+\z!);
	my ($db) = (PublicInbox::Import::default_branch() =~ m!([^/]+)\z!);
	my $dir = "t/data-gen/$base.$ident-$db";
	my $new = !-d $dir;
	if ($new) {
		mkdir $dir; # may race
		-d $dir or BAIL_OUT "$dir could not be created: $!";
	}
	my $lk = bless { lock_path => "$dir/creat.lock" }, 'PublicInbox::Lock';
	$opt{inboxdir} = File::Spec->rel2abs($dir);
	$opt{name} //= $ident;
	my $scope = $lk->lock_for_scope;
	my $pre_cb = delete $opt{pre_cb};
	$pre_cb->($dir) if $pre_cb && $new;
	$opt{-no_fsync} = 1;
	my $no_gc = delete $opt{-no_gc};
	my $tmpdir = delete $opt{tmpdir};
	my $addr = $opt{address} // [];
	$opt{-primary_address} //= $addr->[0] // "$ident\@example.com";
	my $parallel = delete($opt{importer_parallel}) // 0;
	my $creat_opt = { nproc => delete($opt{nproc}) // 1 };
	my $ibx = PublicInbox::InboxWritable->new({ %opt }, $creat_opt);
	if (!-f "$dir/creat.stamp") {
		my $im = $ibx->importer($parallel);
		$cb->($im, $ibx);
		$im->done if $im;
		unless ($no_gc) {
			my @to_gc = $ibx->version == 1 ? ($ibx->{inboxdir}) :
					glob("$ibx->{inboxdir}/git/*.git");
			for my $dir (@to_gc) {
				xsys_e([ qw(git gc -q) ], { GIT_DIR => $dir });
			}
		}
		open my $s, '>', "$dir/creat.stamp" or
			BAIL_OUT "error creating $dir/creat.stamp: $!";
	}
	if ($tmpdir) {
		undef $ibx;
		xsys([qw(/bin/cp -Rp), $dir, $tmpdir]) == 0 or
			BAIL_OUT "cp $dir $tmpdir";
		$opt{inboxdir} = $tmpdir;
		$ibx = PublicInbox::InboxWritable->new(\%opt);
	}
	$ibx;
}

sub test_httpd ($$;$) {
	my ($env, $client, $skip) = @_;
	for (qw(PI_CONFIG TMPDIR)) {
		$env->{$_} or BAIL_OUT "$_ unset";
	}
	SKIP: {
		require_mods(qw(Plack::Test::ExternalServer), $skip // 1);
		my $sock = tcp_server() or die;
		my ($out, $err) = map { "$env->{TMPDIR}/std$_.log" } qw(out err);
		my $cmd = [ qw(-httpd -W0), "--stdout=$out", "--stderr=$err" ];
		my $td = start_script($cmd, $env, { 3 => $sock });
		my ($h, $p) = tcp_host_port($sock);
		local $ENV{PLACK_TEST_EXTERNALSERVER_URI} = "http://$h:$p";
		Plack::Test::ExternalServer::test_psgi(client => $client);
		$td->join('TERM');
		open my $fh, '<', $err or BAIL_OUT $!;
		my $e = do { local $/; <$fh> };
		if ($e =~ s/^Plack::Middleware::ReverseProxy missing,\n//gms) {
			$e =~ s/^URL generation for redirects .*\n//gms;
		}
		is($e, '', 'no errors');
	}
};


package PublicInbox::TestCommon::InboxWakeup;
use strict;
sub on_inbox_unlock { ${$_[0]}->($_[1]) }

1;
