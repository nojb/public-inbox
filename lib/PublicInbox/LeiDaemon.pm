# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Backend for `lei' (local email interface).  Unlike the C10K-oriented
# PublicInbox::Daemon, this is designed exclusively to handle trusted
# local clients with read/write access to the FS and use as many
# system resources as the local user has access to.
package PublicInbox::LeiDaemon;
use strict;
use v5.10.1;
use parent qw(PublicInbox::DS);
use Getopt::Long ();
use Errno qw(EAGAIN ECONNREFUSED ENOENT);
use POSIX qw(setsid);
use IO::Socket::UNIX;
use IO::Handle ();
use Sys::Syslog qw(syslog openlog);
use PublicInbox::Syscall qw($SFD_NONBLOCK EPOLLIN EPOLLONESHOT);
use PublicInbox::Sigfd;
use PublicInbox::DS qw(now);
use PublicInbox::Spawn qw(spawn);
our $quit = sub { exit(shift // 0) };
my $glp = Getopt::Long::Parser->new;
$glp->configure(qw(gnu_getopt no_ignore_case auto_abbrev));

# TBD: this is a documentation mechanism to show a subcommand
# (may) pass options through to another command:
sub pass_through { () }

# TODO: generate shell completion + help using %CMD and %OPTDESC
# command => [ positional_args, 1-line description, Getopt::Long option spec ]
our %CMD = ( # sorted in order of importance/use:
'query' => [ 'SEARCH-TERMS...', 'search for messages matching terms', qw(
	save-as=s output|o=s format|f=s dedupe|d=s thread|t augment|a
	limit|n=i sort|s=s reverse|r offset=i remote local! extinbox!
	since|after=s until|before=s) ],

'show' => [ '{MID|OID}', 'show a given object (Message-ID or object ID)',
	qw(type=s solve! format|f=s dedupe|d=s thread|t remote local!),
	pass_through('git show') ],

'add-extinbox' => [ 'URL-OR-PATHNAME',
	'add/set priority of a publicinbox|extindex for extra matches',
	qw(prio=i) ],
'ls-extinbox' => [ '[FILTER]', 'list publicinbox|extindex locations',
	qw(format|f=s z local remote) ],
'forget-extinbox' => [ '{URL-OR-PATHNAME|--prune}',
	'exclude further results from a publicinbox|extindex',
	qw(prune) ],

'ls-query' => [ '[FILTER]', 'list saved search queries',
		qw(name-only format|f=s z) ],
'rm-query' => [ 'QUERY_NAME', 'remove a saved search' ],
'mv-query' => [ qw(OLD_NAME NEW_NAME), 'rename a saved search' ],

'plonk' => [ '{--thread|--from=IDENT}',
	'exclude mail matching From: or thread from non-Message-ID searches',
	qw(thread|t from|f=s mid=s oid=s) ],
'mark' => [ 'MESSAGE-FLAGS', 'set/unset flags on message(s) from stdin',
	qw(stdin| oid=s exact by-mid|mid:s) ],
'forget' => [ '--stdin', 'exclude message(s) on stdin from query results',
	qw(stdin| oid=s  exact by-mid|mid:s) ],

'purge-mailsource' => [ '{URL-OR-PATHNAME|--all}',
	'remove imported messages from IMAP, Maildirs, and MH',
	qw(exact! all jobs:i indexed) ],

# code repos are used for `show' to solve blobs from patch mails
'add-coderepo' => [ 'PATHNAME', 'add or set priority of a git code repo',
	qw(prio=i) ],
'ls-coderepo' => [ '[FILTER]', 'list known code repos', qw(format|f=s z) ],
'forget-coderepo' => [ 'PATHNAME',
	'stop using repo to solve blobs from patches',
	qw(prune) ],

'add-watch' => [ '[URL_OR_PATHNAME]',
		'watch for new messages and flag changes',
	qw(import! flags! interval=s recursive|r exclude=s include=s) ],
'ls-watch' => [ '[FILTER]', 'list active watches with numbers and status',
		qw(format|f=s z) ],
'pause-watch' => [ '[WATCH_NUMBER_OR_FILTER]', qw(all local remote) ],
'resume-watch' => [ '[WATCH_NUMBER_OR_FILTER]', qw(all local remote) ],
'forget-watch' => [ '{WATCH_NUMBER|--prune}', 'stop and forget a watch',
	qw(prune) ],

'import' => [ '{URL_OR_PATHNAME|--stdin}',
	'one-shot import/update from URL or filesystem',
	qw(stdin| limit|n=i offset=i recursive|r exclude=s include=s !flags),
	],

'config' => [ '[ANYTHING...]',
		'git-config(1) wrapper for ~/.config/lei/config',
		pass_through('git config') ],
'daemon-stop' => [ undef, 'stop the lei-daemon' ],
'daemon-pid' => [ undef, 'show the PID of the lei-daemon' ],
'help' => [ '[SUBCOMMAND]', 'show help' ],

# XXX do we need this?
# 'git' => [ '[ANYTHING...]', 'git(1) wrapper', pass_through('git') ],

'reorder-local-store-and-break-history' => [ '[REFNAME]',
	'rewrite git history in an attempt to improve compression',
	'gc!' ]
); # @CMD

# switch descriptions, try to keep consistent across commands
# $spec: Getopt::Long option specification
# $spec => [@ALLOWED_VALUES (default is first), $description],
# $spec => $description
# "$SUB_COMMAND TAB $spec" => as above
my $stdin_formats = [ qw(auto raw mboxrd mboxcl2 mboxcl mboxo),
		'specify message input format' ];
my $ls_format = [ qw(plain json null), 'listing output format' ];
my $show_format = [ qw(plain raw html mboxrd mboxcl2 mboxcl),
		'message/object output format' ];

my %OPTDESC = (
'solve!' => 'do not attempt to reconstruct blobs from emails',
'save-as=s' => 'save a search terms by given name',

'type=s' => [qw(any mid git), 'disambiguate type' ],

'dedupe|d=s' => [qw(content oid mid), 'deduplication strategy'],
'thread|t' => 'every message in the same thread as the actual match(es)',
'augment|a' => 'augment --output destination instead of clobbering',

'output|o=s' => "destination (e.g. `/path/to/Maildir', or `-' for stdout)",

'mark	format|f=s' => $stdin_formats,
'forget	format|f=s' => $stdin_formats,
'query	format|f=s' => [qw(maildir mboxrd mboxcl2 mboxcl html oid),
		q[specify output format (default: determined by --output)]],
'ls-query	format|f=s' => $ls_format,
'ls-extinbox format|f=s' => $ls_format,

'limit|n=i' => 'integer limit on number of matches (default: 10000)',
'offset=i' => 'search result offset (default: 0)',

'sort|s=s@' => [qw(internaldate date relevance docid),
		"order of results `--output'-dependent)"],

'prio=i' => 'priority of query source',

'local' => 'limit operations to the local filesystem',
'local!' => 'exclude results from the local filesystem',
'remote' => 'limit operations to those requiring network access',
'remote!' => 'prevent operations requiring network access',

'mid=s' => 'specify the Message-ID of a message',
'oid=s' => 'specify the git object ID of a message',

'recursive|r' => 'scan directories/mailboxes/newsgroups recursively',
'exclude=s' => 'exclude mailboxes/newsgroups based on pattern',
'include=s' => 'include mailboxes/newsgroups based on pattern',

'exact' => 'operate on exact header matches only',
'exact!' => 'rely on content match instead of exact header matches',

'by-mid|mid:s' => 'match only by Message-ID, ignoring contents',
'jobs:i' => 'set parallelism level',
); # %OPTDESC

sub x_it ($$) { # pronounced "exit"
	my ($client, $code) = @_;
	if (my $sig = ($code & 127)) {
		kill($sig, $client->{pid} // $$);
	} else {
		$code >>= 8;
		if (my $sock = $client->{sock}) {
			say $sock "exit=$code";
		} else { # for oneshot
			$quit->($code);
		}
	}
}

sub emit ($$$) {
	my ($client, $channel, $buf) = @_;
	print { $client->{$channel} } $buf or warn "print FD[$channel]: $!";
}

sub fail ($$;$) {
	my ($client, $buf, $exit_code) = @_;
	$buf .= "\n" unless $buf =~ /\n\z/s;
	emit($client, 2, $buf);
	x_it($client, ($exit_code // 1) << 8);
	undef;
}

sub _help ($;$) {
	my ($client, $channel) = @_;
	emit($client, $channel //= 1, <<EOF);
usage: lei COMMAND [OPTIONS]

...
EOF
	x_it($client, $channel == 2 ? 1 << 8 : 0); # stderr => failure
}

sub assert_args ($$$;$@) {
	my ($client, $argv, $proto, $opt, @spec) = @_;
	$opt //= {};
	push @spec, qw(help|h);
	$glp->getoptionsfromarray($argv, $opt, @spec) or
		return fail($client, 'bad arguments or options');
	if ($opt->{help}) {
		_help($client);
		undef;
	} else {
		my ($nreq, $rest) = split(/;/, $proto);
		$nreq = (($nreq // '') =~ tr/$/$/);
		my $argc = scalar(@$argv);
		my $tot = ($rest // '') eq '@' ? $argc : ($proto =~ tr/$/$/);
		return 1 if $argc <= $tot && $argc >= $nreq;
		_help($client, 2);
		undef
	}
}

sub dispatch {
	my ($client, $cmd, @argv) = @_;
	local $SIG{__WARN__} = sub { emit($client, 2, "@_") };
	local $SIG{__DIE__} = 'DEFAULT';
	if (defined $cmd) {
		my $func = "lei_$cmd";
		$func =~ tr/-/_/;
		if (my $cb = __PACKAGE__->can($func)) {
			$client->{cmd} = $cmd;
			$cb->($client, \@argv);
		} elsif (grep(/\A-/, $cmd, @argv)) {
			assert_args($client, [ $cmd, @argv ], '');
		} else {
			fail($client, "`$cmd' is not an lei command");
		}
	} else {
		_help($client, 2);
	}
}

sub lei_daemon_pid {
	my ($client, $argv) = @_;
	assert_args($client, $argv, '') and emit($client, 1, "$$\n");
}

sub lei_DBG_pwd {
	my ($client, $argv) = @_;
	assert_args($client, $argv, '') and
		emit($client, 1, "$client->{env}->{PWD}\n");
}

sub lei_DBG_cwd {
	my ($client, $argv) = @_;
	require Cwd;
	assert_args($client, $argv, '') and emit($client, 1, Cwd::cwd()."\n");
}

sub lei_DBG_false { x_it($_[0], 1 << 8) }

sub lei_daemon_stop {
	my ($client, $argv) = @_;
	assert_args($client, $argv, '') and $quit->(0);
}

sub lei_help { _help($_[0]) }

sub reap_exec { # dwaitpid callback
	my ($client, $pid) = @_;
	x_it($client, $?);
}

sub lei_git { # support passing through random git commands
	my ($client, $argv) = @_;
	my %opt = map { $_ => $client->{$_} } (0..2);
	my $pid = spawn(['git', @$argv], $client->{env}, \%opt);
	PublicInbox::DS::dwaitpid($pid, \&reap_exec, $client);
}

sub accept_dispatch { # Listener {post_accept} callback
	my ($sock) = @_; # ignore other
	$sock->blocking(1);
	$sock->autoflush(1);
	my $client = { sock => $sock };
	vec(my $rin = '', fileno($sock), 1) = 1;
	# `say $sock' triggers "die" in lei(1)
	for my $i (0..2) {
		if (select(my $rout = $rin, undef, undef, 1)) {
			my $fd = IO::FDPass::recv(fileno($sock));
			if ($fd >= 0) {
				my $rdr = ($fd == 0 ? '<&=' : '>&=');
				if (open(my $fh, $rdr, $fd)) {
					$client->{$i} = $fh;
				} else {
					say $sock "open($rdr$fd) (FD=$i): $!";
					return;
				}
			} else {
				say $sock "recv FD=$i: $!";
				return;
			}
		} else {
			say $sock "timed out waiting to recv FD=$i";
			return;
		}
	}
	# $ARGV_STR = join("]\0[", @ARGV);
	# $ENV_STR = join('', map { "$_=$ENV{$_}\0" } keys %ENV);
	# $line = "$$\0\0>$ARGV_STR\0\0>$ENV_STR\0\0";
	my ($client_pid, $argv, $env) = do {
		local $/ = "\0\0\0"; # yes, 3 NULs at EOL, not 2
		chomp(my $line = <$sock>);
		split(/\0\0>/, $line, 3);
	};
	my %env = map { split(/=/, $_, 2) } split(/\0/, $env);
	if (chdir($env{PWD})) {
		$client->{env} = \%env;
		$client->{pid} = $client_pid;
		eval { dispatch($client, split(/\]\0\[/, $argv)) };
		say $sock $@ if $@;
	} else {
		say $sock "chdir($env{PWD}): $!"; # implicit close
	}
}

sub noop {}

# lei(1) calls this when it can't connect
sub lazy_start {
	my ($path, $err) = @_;
	if ($err == ECONNREFUSED) {
		unlink($path) or die "unlink($path): $!";
	} elsif ($err != ENOENT) {
		die "connect($path): $!";
	}
	require IO::FDPass;
	my $umask = umask(077) // die("umask(077): $!");
	my $l = IO::Socket::UNIX->new(Local => $path,
					Listen => 1024,
					Type => SOCK_STREAM) or
		$err = $!;
	umask($umask) or die("umask(restore): $!");
	$l or return die "bind($path): $err";
	my @st = stat($path) or die "stat($path): $!";
	my $dev_ino_expect = pack('dd', $st[0], $st[1]); # dev+ino
	pipe(my ($eof_r, $eof_w)) or die "pipe: $!";
	my $oldset = PublicInbox::Sigfd::block_signals();
	my $pid = fork // die "fork: $!";
	return if $pid;
	openlog($path, 'pid', 'user');
	local $SIG{__DIE__} = sub {
		syslog('crit', "@_");
		exit $! if $!;
		exit $? >> 8 if $? >> 8;
		exit 255;
	};
	local $SIG{__WARN__} = sub { syslog('warning', "@_") };
	open(STDIN, '+<', '/dev/null') or die "redirect stdin failed: $!\n";
	open STDOUT, '>&STDIN' or die "redirect stdout failed: $!\n";
	open STDERR, '>&STDIN' or die "redirect stderr failed: $!\n";
	setsid();
	$pid = fork // die "fork: $!";
	return if $pid;
	$0 = "lei-daemon $path";
	require PublicInbox::Listener;
	require PublicInbox::EOFpipe;
	$l->blocking(0);
	$eof_w->blocking(0);
	$eof_r->blocking(0);
	my $listener = PublicInbox::Listener->new($l, \&accept_dispatch, $l);
	my $exit_code;
	local $quit = sub {
		$exit_code //= shift;
		my $tmp = $listener or exit($exit_code);
		unlink($path) if defined($path);
		syswrite($eof_w, '.');
		$l = $listener = $path = undef;
		$tmp->close if $tmp; # DS::close
		PublicInbox::DS->SetLoopTimeout(1000);
	};
	PublicInbox::EOFpipe->new($eof_r, sub {}, undef);
	my $sig = {
		CHLD => \&PublicInbox::DS::enqueue_reap,
		QUIT => $quit,
		INT => $quit,
		TERM => $quit,
		HUP => \&noop,
		USR1 => \&noop,
		USR2 => \&noop,
	};
	my $sigfd = PublicInbox::Sigfd->new($sig, $SFD_NONBLOCK);
	local %SIG = (%SIG, %$sig) if !$sigfd;
	if ($sigfd) { # TODO: use inotify/kqueue to detect unlinked sockets
		PublicInbox::DS->SetLoopTimeout(5000);
	} else {
		# wake up every second to accept signals if we don't
		# have signalfd or IO::KQueue:
		PublicInbox::Sigfd::sig_setmask($oldset);
		PublicInbox::DS->SetLoopTimeout(1000);
	}
	PublicInbox::DS->SetPostLoopCallback(sub {
		my ($dmap, undef) = @_;
		if (@st = defined($path) ? stat($path) : ()) {
			if ($dev_ino_expect ne pack('dd', $st[0], $st[1])) {
				warn "$path dev/ino changed, quitting\n";
				$path = undef;
			}
		} elsif (defined($path)) {
			warn "stat($path): $!, quitting ...\n";
			undef $path; # don't unlink
			$quit->();
		}
		return 1 if defined($path);
		my $now = now();
		my $n = 0;
		for my $s (values %$dmap) {
			$s->can('busy') or next;
			if ($s->busy($now)) {
				++$n;
			} else {
				$s->close;
			}
		}
		$n; # true: continue, false: stop
	});
	PublicInbox::DS->EventLoop;
	exit($exit_code // 0);
}

# for users w/o IO::FDPass
sub oneshot {
	dispatch({
		0 => *STDIN{IO},
		1 => *STDOUT{IO},
		2 => *STDERR{IO},
		env => \%ENV
	}, @ARGV);
}

1;
