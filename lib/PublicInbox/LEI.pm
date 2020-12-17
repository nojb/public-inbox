# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Backend for `lei' (local email interface).  Unlike the C10K-oriented
# PublicInbox::Daemon, this is designed exclusively to handle trusted
# local clients with read/write access to the FS and use as many
# system resources as the local user has access to.
package PublicInbox::LEI;
use strict;
use v5.10.1;
use parent qw(PublicInbox::DS);
use Getopt::Long ();
use Errno qw(EAGAIN ECONNREFUSED ENOENT);
use POSIX qw(setsid);
use IO::Socket::UNIX;
use IO::Handle ();
use Sys::Syslog qw(syslog openlog);
use PublicInbox::Config;
use PublicInbox::Syscall qw($SFD_NONBLOCK EPOLLIN EPOLLONESHOT);
use PublicInbox::Sigfd;
use PublicInbox::DS qw(now);
use PublicInbox::Spawn qw(spawn);
use Text::Wrap qw(wrap);
use File::Path qw(mkpath);
use File::Spec;
our $quit = \&CORE::exit;
my $GLP = Getopt::Long::Parser->new;
$GLP->configure(qw(gnu_getopt no_ignore_case auto_abbrev));
my $GLP_PASS = Getopt::Long::Parser->new;
$GLP_PASS->configure(qw(gnu_getopt no_ignore_case auto_abbrev pass_through));

our %PATH2CFG; # persistent for socket daemon

# TBD: this is a documentation mechanism to show a subcommand
# (may) pass options through to another command:
sub pass_through { $GLP_PASS }

# TODO: generate shell completion + help using %CMD and %OPTDESC
# command => [ positional_args, 1-line description, Getopt::Long option spec ]
our %CMD = ( # sorted in order of importance/use:
'query' => [ 'SEARCH_TERMS...', 'search for messages matching terms', qw(
	save-as=s output|o=s format|f=s dedupe|d=s thread|t augment|a
	limit|n=i sort|s=s@ reverse|r offset=i remote local! extinbox!
	since|after=s until|before=s) ],

'show' => [ 'MID|OID', 'show a given object (Message-ID or object ID)',
	qw(type=s solve! format|f=s dedupe|d=s thread|t remote local!),
	pass_through('git show') ],

'add-extinbox' => [ 'URL_OR_PATHNAME',
	'add/set priority of a publicinbox|extindex for extra matches',
	qw(prio=i) ],
'ls-extinbox' => [ '[FILTER...]', 'list publicinbox|extindex locations',
	qw(format|f=s z local remote) ],
'forget-extinbox' => [ '{URL_OR_PATHNAME|--prune}',
	'exclude further results from a publicinbox|extindex',
	qw(prune) ],

'ls-query' => [ '[FILTER...]', 'list saved search queries',
		qw(name-only format|f=s z) ],
'rm-query' => [ 'QUERY_NAME', 'remove a saved search' ],
'mv-query' => [ qw(OLD_NAME NEW_NAME), 'rename a saved search' ],

'plonk' => [ '--thread|--from=IDENT',
	'exclude mail matching From: or thread from non-Message-ID searches',
	qw(stdin| thread|t from|f=s mid=s oid=s) ],
'mark' => [ 'MESSAGE_FLAGS...',
	'set/unset flags on message(s) from stdin',
	qw(stdin| oid=s exact by-mid|mid:s) ],
'forget' => [ '[--stdin|--oid=OID|--by-mid=MID]',
	'exclude message(s) on stdin from query results',
	qw(stdin| oid=s exact by-mid|mid:s quiet|q) ],

'purge-mailsource' => [ '{URL_OR_PATHNAME|--all}',
	'remove imported messages from IMAP, Maildirs, and MH',
	qw(exact! all jobs:i indexed) ],

# code repos are used for `show' to solve blobs from patch mails
'add-coderepo' => [ 'PATHNAME', 'add or set priority of a git code repo',
	qw(prio=i) ],
'ls-coderepo' => [ '[FILTER_TERMS...]',
		'list known code repos', qw(format|f=s z) ],
'forget-coderepo' => [ 'PATHNAME',
	'stop using repo to solve blobs from patches',
	qw(prune) ],

'add-watch' => [ '[URL_OR_PATHNAME]',
		'watch for new messages and flag changes',
	qw(import! flags! interval=s recursive|r exclude=s include=s) ],
'ls-watch' => [ '[FILTER...]', 'list active watches with numbers and status',
		qw(format|f=s z) ],
'pause-watch' => [ '[WATCH_NUMBER_OR_FILTER]', qw(all local remote) ],
'resume-watch' => [ '[WATCH_NUMBER_OR_FILTER]', qw(all local remote) ],
'forget-watch' => [ '{WATCH_NUMBER|--prune}', 'stop and forget a watch',
	qw(prune) ],

'import' => [ '{URL_OR_PATHNAME|--stdin}',
	'one-shot import/update from URL or filesystem',
	qw(stdin| limit|n=i offset=i recursive|r exclude=s include=s !flags),
	],

'config' => [ '[...]', 'git-config(1) wrapper for ~/.config/lei/config',
	qw(config-file|system|global|file|f=s), # conflict detection
	pass_through('git config') ],
'init' => [ '[PATHNAME]',
	'initialize storage, default: ~/.local/share/lei/store',
	qw(quiet|q) ],
'daemon-stop' => [ '', 'stop the lei-daemon' ],
'daemon-pid' => [ '', 'show the PID of the lei-daemon' ],
'daemon-env' => [ '[NAME=VALUE...]', 'set, unset, or show daemon environment',
	qw(clear| unset|u=s@ z|0) ],
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
my $stdin_formats = [ 'IN|auto|raw|mboxrd|mboxcl2|mboxcl|mboxo',
		'specify message input format' ];
my $ls_format = [ 'OUT|plain|json|null', 'listing output format' ];

my %OPTDESC = (
'help|h' => 'show this built-in help',
'quiet|q' => 'be quiet',
'solve!' => 'do not attempt to reconstruct blobs from emails',
'save-as=s' => ['NAME', 'save a search terms by given name'],

'type=s' => [ 'any|mid|git', 'disambiguate type' ],

'dedupe|d=s' => ['STRAT|content|oid|mid',
		'deduplication strategy'],
'show	thread|t' => 'display entire thread a message belongs to',
'query	thread|t' =>
	'return all messages in the same thread as the actual match(es)',
'augment|a' => 'augment --output destination instead of clobbering',

'output|o=s' => [ 'DEST',
	"destination (e.g. `/path/to/Maildir', or `-' for stdout)" ],

'show	format|f=s' => [ 'OUT|plain|raw|html|mboxrd|mboxcl2|mboxcl',
			'message/object output format' ],
'mark	format|f=s' => $stdin_formats,
'forget	format|f=s' => $stdin_formats,
'query	format|f=s' => [ 'OUT|maildir|mboxrd|mboxcl2|mboxcl|html|oid',
		'specify output format, default depends on --output'],
'ls-query	format|f=s' => $ls_format,
'ls-extinbox	format|f=s' => $ls_format,

'limit|n=i' => ['NUM',
	'limit on number of matches (default: 10000)' ],
'offset=i' => ['OFF', 'search result offset (default: 0)'],

'sort|s=s@' => [ 'VAL|internaldate,date,relevance,docid',
		"order of results `--output'-dependent"],

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

'by-mid|mid:s' => [ 'MID', 'match only by Message-ID, ignoring contents' ],
'jobs:i' => 'set parallelism level',

# xargs, env, use "-0", git(1) uses "-z".  Should we support z|0 everywhere?
'z' => 'use NUL \\0 instead of newline (CR) to delimit lines',
'z|0' => 'use NUL \\0 instead of newline (CR) to delimit lines',

# note: no "--ignore-environment" / "-i" support like env(1) since that
# is one-shot and this is for a persistent daemon:
'clear|' => 'clear the daemon environment',
'unset|u=s@' => ['NAME',
	'unset matching NAME, may be specified multiple times'],
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

sub emit {
	my ($client, $channel) = @_; # $buf = $_[2]
	print { $client->{$channel} } $_[2] or die "print FD[$channel]: $!";
}

sub err {
	my ($client, $buf) = @_;
	$buf .= "\n" unless $buf =~ /\n\z/s;
	emit($client, 2, $buf);
}

sub qerr { $_[0]->{opt}->{quiet} or err(@_) }

sub fail ($$;$) {
	my ($client, $buf, $exit_code) = @_;
	err($client, $buf);
	x_it($client, ($exit_code // 1) << 8);
	undef;
}

sub _help ($;$) {
	my ($client, $errmsg) = @_;
	my $cmd = $client->{cmd} // 'COMMAND';
	my @info = @{$CMD{$cmd} // [ '...', '...' ]};
	my @top = ($cmd, shift(@info) // ());
	my $cmd_desc = shift(@info);
	my @opt_desc;
	my $lpad = 2;
	for my $sw (grep { !ref($_) } @info) { # ("prio=s", "z", $GLP_PASS)
		my $desc = $OPTDESC{"$cmd\t$sw"} // $OPTDESC{$sw} // next;
		my $arg_vals = '';
		($arg_vals, $desc) = @$desc if ref($desc) eq 'ARRAY';

		# lower-case is a keyword (e.g. `content', `oid'),
		# ALL_CAPS is a string description (e.g. `PATH')
		if ($desc !~ /default/ && $arg_vals =~ /\b([a-z]+)[,\|]/) {
			$desc .= "\ndefault: `$1'";
		}
		my (@vals, @s, @l);
		my $x = $sw;
		if ($x =~ s/!\z//) { # solve! => --no-solve
			$x = "no-$x";
		} elsif ($x =~ s/:.+//) { # optional args: $x = "mid:s"
			@vals = (' [', undef, ']');
		} elsif ($x =~ s/=.+//) { # required arg: $x = "type=s"
			@vals = (' ', undef);
		} # else: no args $x = 'thread|t'
		for (split(/\|/, $x)) { # help|h
			length($_) > 1 ? push(@l, "--$_") : push(@s, "-$_");
		}
		if (!scalar(@vals)) { # no args 'thread|t'
		} elsif ($arg_vals =~ s/\A([A-Z_]+)\b//) { # "NAME"
			$vals[1] = $1;
		} else {
			$vals[1] = uc(substr($l[0], 2)); # "--type" => "TYPE"
		}
		if ($arg_vals =~ /([,\|])/) {
			my $sep = $1;
			my @allow = split(/\Q$sep\E/, $arg_vals);
			my $must = $sep eq '|' ? 'Must' : 'Can';
			@allow = map { "`$_'" } @allow;
			my $last = pop @allow;
			$desc .= "\n$must be one of: " .
				join(', ', @allow) . " or $last";
		}
		my $lhs = join(', ', @s, @l) . join('', @vals);
		if ($x =~ /\|\z/) { # "stdin|" or "clear|"
			$lhs =~ s/\A--/- , --/;
		} else {
			$lhs =~ s/\A--/    --/; # pad if no short options
		}
		$lpad = length($lhs) if length($lhs) > $lpad;
		push @opt_desc, $lhs, $desc;
	}
	my $msg = $errmsg ? "E: $errmsg\n" : '';
	$msg .= <<EOF;
usage: lei @top
  $cmd_desc

EOF
	$lpad += 2;
	local $Text::Wrap::columns = 78 - $lpad;
	my $padding = ' ' x ($lpad + 2);
	while (my ($lhs, $rhs) = splice(@opt_desc, 0, 2)) {
		$msg .= '  '.pack("A$lpad", $lhs);
		$rhs = wrap('', '', $rhs);
		$rhs =~ s/\n/\n$padding/sg; # LHS pad continuation lines
		$msg .= $rhs;
		$msg .= "\n";
	}
	my $channel = $errmsg ? 2 : 1;
	emit($client, $channel, $msg);
	x_it($client, $errmsg ? 1 << 8 : 0); # stderr => failure
	undef;
}

sub optparse ($$$) {
	my ($client, $cmd, $argv) = @_;
	$client->{cmd} = $cmd;
	my $opt = $client->{opt} = {};
	my $info = $CMD{$cmd} // [ '[...]', '(undocumented command)' ];
	my ($proto, $desc, @spec) = @$info;
	my $glp = ref($spec[-1]) ? pop(@spec) : $GLP; # or $GLP_PASS
	push @spec, qw(help|h);
	my $lone_dash;
	if ($spec[0] =~ s/\|\z//s) { # "stdin|" or "clear|" allows "-" alias
		$lone_dash = $spec[0];
		$opt->{$spec[0]} = \(my $var);
		push @spec, '' => \$var;
	}
	$glp->getoptionsfromarray($argv, $opt, @spec) or
		return _help($client, "bad arguments or options for $cmd");
	return _help($client) if $opt->{help};

	# "-" aliases "stdin" or "clear"
	$opt->{$lone_dash} = ${$opt->{$lone_dash}} if defined $lone_dash;

	my $i = 0;
	my $POS_ARG = '[A-Z][A-Z0-9_]+';
	my ($err, $inf);
	my @args = split(/ /, $proto);
	for my $var (@args) {
		if ($var =~ /\A$POS_ARG\.\.\.\z/o) { # >= 1 args;
			$inf = defined($argv->[$i]) and last;
			$var =~ s/\.\.\.\z//;
			$err = "$var not supplied";
		} elsif ($var =~ /\A$POS_ARG\z/o) { # required arg at $i
			$argv->[$i++] // ($err = "$var not supplied");
		} elsif ($var =~ /\.\.\.\]\z/) { # optional args start
			$inf = 1;
			last;
		} elsif ($var =~ /\A\[$POS_ARG\]\z/) { # one optional arg
			$i++;
		} elsif ($var =~ /\A.+?\|/) { # required FOO|--stdin
			my @or = split(/\|/, $var);
			my $ok;
			for my $o (@or) {
				if ($o =~ /\A--([a-z0-9\-]+)/) {
					$ok = defined($opt->{$1});
					last;
				} elsif (defined($argv->[$i])) {
					$ok = 1;
					$i++;
					last;
				} # else continue looping
			}
			my $last = pop @or;
			$err = join(', ', @or) . " or $last must be set";
		} else {
			warn "BUG: can't parse `$var' in $proto";
		}
		last if $err;
	}
	# warn "inf=$inf ".scalar(@$argv). ' '.scalar(@args)."\n";
	if (!$inf && scalar(@$argv) > scalar(@args)) {
		$err //= 'too many arguments';
	}
	$err ? fail($client, "usage: lei $cmd $proto\nE: $err") : 1;
}

sub dispatch {
	my ($client, $cmd, @argv) = @_;
	local $SIG{__WARN__} = sub { err($client, "@_") };
	local $SIG{__DIE__} = 'DEFAULT';
	return _help($client, 'no command given') unless defined($cmd);
	my $func = "lei_$cmd";
	$func =~ tr/-/_/;
	if (my $cb = __PACKAGE__->can($func)) {
		optparse($client, $cmd, \@argv) or return;
		$cb->($client, @argv);
	} elsif (grep(/\A-/, $cmd, @argv)) { # --help or -h only
		my $opt = {};
		$GLP->getoptionsfromarray([$cmd, @argv], $opt, qw(help|h)) or
			return _help($client, 'bad arguments or options');
		_help($client);
	} else {
		fail($client, "`$cmd' is not an lei command");
	}
}

sub _lei_cfg ($;$) {
	my ($client, $creat) = @_;
	my $env = $client->{env};
	my $cfg_dir = File::Spec->canonpath(( $env->{XDG_CONFIG_HOME} //
			($env->{HOME} // '/nonexistent').'/.config').'/lei');
	my $f = "$cfg_dir/config";
	my @st = stat($f);
	my $cur_st = @st ? pack('dd', $st[10], $st[7]) : ''; # 10:ctime, 7:size
	if (my $cfg = $PATH2CFG{$f}) { # reuse existing object in common case
		return ($client->{cfg} = $cfg) if $cur_st eq $cfg->{-st};
	}
	if (!@st) {
		unless ($creat) {
			delete $client->{cfg};
			return;
		}
		-d $cfg_dir or mkpath($cfg_dir) or die "mkpath($cfg_dir): $!\n";
		open my $fh, '>>', $f or die "open($f): $!\n";
		@st = stat($fh) or die "fstat($f): $!\n";
		$cur_st = pack('dd', $st[10], $st[7]);
		qerr($client, "I: $f created") if $client->{cmd} ne 'config';
	}
	my $cfg = PublicInbox::Config::git_config_dump($f);
	$cfg->{-st} = $cur_st;
	$cfg->{'-f'} = $f;
	$client->{cfg} = $PATH2CFG{$f} = $cfg;
}

sub _lei_store ($;$) {
	my ($client, $creat) = @_;
	my $cfg = _lei_cfg($client, $creat);
	$cfg->{-lei_store} //= do {
		require PublicInbox::LeiStore;
		PublicInbox::SearchIdx::load_xapian_writable();
		defined(my $dir = $cfg->{'leistore.dir'}) or return;
		PublicInbox::LeiStore->new($dir, { creat => $creat });
	};
}

sub lei_show {
	my ($client, @argv) = @_;
}

sub lei_query {
	my ($client, @argv) = @_;
}

sub lei_mark {
	my ($client, @argv) = @_;
}

sub lei_config {
	my ($client, @argv) = @_;
	$client->{opt}->{'config-file'} and return fail $client,
		"config file switches not supported by `lei config'";
	my $env = $client->{env};
	delete local $env->{GIT_CONFIG};
	my $cfg = _lei_cfg($client, 1);
	my $cmd = [ qw(git config -f), $cfg->{'-f'}, @argv ];
	my %rdr = map { $_ => $client->{$_} } (0..2);
	require PublicInbox::Import;
	PublicInbox::Import::run_die($cmd, $env, \%rdr);
}

sub lei_init {
	my ($client, $dir) = @_;
	my $cfg = _lei_cfg($client, 1);
	my $cur = $cfg->{'leistore.dir'};
	my $env = $client->{env};
	$dir //= ( $env->{XDG_DATA_HOME} //
		($env->{HOME} // '/nonexistent').'/.local/share'
		) . '/lei/store';
	$dir = File::Spec->rel2abs($dir, $env->{PWD}); # PWD is symlink-aware
	my @cur = stat($cur) if defined($cur);
	$cur = File::Spec->canonpath($cur) if $cur;
	my @dir = stat($dir);
	my $exists = "I: leistore.dir=$cur already initialized" if @dir;
	if (@cur) {
		if ($cur eq $dir) {
			_lei_store($client, 1)->done;
			return qerr($client, $exists);
		}

		# some folks like symlinks and bind mounts :P
		if (@dir && "$cur[0] $cur[1]" eq "$dir[0] $dir[1]") {
			lei_config($client, 'leistore.dir', $dir);
			_lei_store($client, 1)->done;
			return qerr($client, "$exists (as $cur)");
		}
		return fail($client, <<"");
E: leistore.dir=$cur already initialized and it is not $dir

	}
	lei_config($client, 'leistore.dir', $dir);
	_lei_store($client, 1)->done;
	$exists //= "I: leistore.dir=$dir newly initialized";
	return qerr($client, $exists);
}

sub lei_daemon_pid { emit($_[0], 1, "$$\n") }

sub lei_daemon_stop { $quit->(0) }

sub lei_daemon_env {
	my ($client, @argv) = @_;
	my $opt = $client->{opt};
	if (defined $opt->{clear}) {
		%ENV = ();
	} elsif (my $u = $opt->{unset}) {
		delete @ENV{@$u};
	}
	if (@argv) {
		%ENV = (%ENV, map { split(/=/, $_, 2) } @argv);
	} elsif (!defined($opt->{clear}) && !$opt->{unset}) {
		my $eor = $opt->{z} ? "\0" : "\n";
		my $buf = '';
		while (my ($k, $v) = each %ENV) { $buf .= "$k=$v$eor" }
		emit($client, 1, $buf)
	}
}

sub lei_help { _help($_[0]) }

sub reap_exec { # dwaitpid callback
	my ($client, $pid) = @_;
	x_it($client, $?);
}

sub lei_git { # support passing through random git commands
	my ($client, @argv) = @_;
	my %rdr = map { $_ => $client->{$_} } (0..2);
	my $pid = spawn(['git', @argv], $client->{env}, \%rdr);
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
	umask(077) // die("umask(077): $!");
	my $l = IO::Socket::UNIX->new(Local => $path,
					Listen => 1024,
					Type => SOCK_STREAM) or
		$err = $!;
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
	local %PATH2CFG;
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
	my ($main_pkg) = @_;
	my $exit = $main_pkg->can('exit'); # caller may override exit()
	local $quit = $exit if $exit;
	local %PATH2CFG;
	umask(077) // die("umask(077): $!");
	dispatch({
		0 => *STDIN{IO},
		1 => *STDOUT{IO},
		2 => *STDERR{IO},
		env => \%ENV
	}, @ARGV);
}

1;
