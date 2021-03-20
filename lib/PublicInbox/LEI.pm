# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Backend for `lei' (local email interface).  Unlike the C10K-oriented
# PublicInbox::Daemon, this is designed exclusively to handle trusted
# local clients with read/write access to the FS and use as many
# system resources as the local user has access to.
package PublicInbox::LEI;
use strict;
use v5.10.1;
use parent qw(PublicInbox::DS PublicInbox::LeiExternal
	PublicInbox::LeiQuery);
use Getopt::Long ();
use Socket qw(AF_UNIX SOCK_SEQPACKET MSG_EOR pack_sockaddr_un);
use Errno qw(EPIPE EAGAIN EINTR ECONNREFUSED ENOENT ECONNRESET);
use Cwd qw(getcwd);
use POSIX qw(strftime);
use IO::Handle ();
use Fcntl qw(SEEK_SET);
use PublicInbox::Config;
use PublicInbox::Syscall qw(SFD_NONBLOCK EPOLLIN EPOLLET);
use PublicInbox::Sigfd;
use PublicInbox::DS qw(now dwaitpid);
use PublicInbox::Spawn qw(spawn popen_rd);
use PublicInbox::Lock;
use Time::HiRes qw(stat); # ctime comparisons for config cache
use File::Path qw(mkpath);
use File::Spec;
our $quit = \&CORE::exit;
our ($current_lei, $errors_log, $listener, $oldset);
my ($recv_cmd, $send_cmd);
my $GLP = Getopt::Long::Parser->new;
$GLP->configure(qw(gnu_getopt no_ignore_case auto_abbrev));
my $GLP_PASS = Getopt::Long::Parser->new;
$GLP_PASS->configure(qw(gnu_getopt no_ignore_case auto_abbrev pass_through));

our %PATH2CFG; # persistent for socket daemon

# TBD: this is a documentation mechanism to show a subcommand
# (may) pass options through to another command:
sub pass_through { $GLP_PASS }

my $OPT;
sub opt_dash ($$) {
	my ($spec, $re_str) = @_; # 'limit|n=i', '([0-9]+)'
	my ($key) = ($spec =~ m/\A([a-z]+)/g);
	my $cb = sub { # Getopt::Long "<>" catch-all handler
		my ($arg) = @_;
		if ($arg =~ /\A-($re_str)\z/) {
			$OPT->{$key} = $1;
		} elsif ($arg eq '--') { # "--" arg separator, ignore first
			push @{$OPT->{-argv}}, $arg if $OPT->{'--'}++;
		# lone (single) dash is handled elsewhere
		} elsif (substr($arg, 0, 1) eq '-') {
			if ($OPT->{'--'}) {
				push @{$OPT->{-argv}}, $arg;
			} else {
				die "bad argument: $arg\n";
			}
		} else {
			push @{$OPT->{-argv}}, $arg;
		}
	};
	($spec, '<>' => $cb, $GLP_PASS) # for Getopt::Long
}

sub rel2abs ($$) {
	my ($self, $p) = @_;
	return $p if index($p, '/') == 0; # already absolute
	my $pwd = $self->{env}->{PWD};
	if (defined $pwd) {
		my $cwd = $self->{3} // getcwd() // die "getcwd(PWD=$pwd): $!";
		if (my @st_pwd = stat($pwd)) {
			my @st_cwd = stat($cwd) or die "stat($cwd): $!";
			"@st_pwd[1,0]" eq "@st_cwd[1,0]" or
				$self->{env}->{PWD} = $pwd = $cwd;
		} else { # PWD was invalid
			delete $self->{env}->{PWD};
			undef $pwd;
		}
	}
	$pwd //= $self->{env}->{PWD} = getcwd() // die "getcwd(PWD=$pwd): $!";
	File::Spec->rel2abs($p, $pwd);
}

sub store_path ($) {
	my ($self) = @_;
	rel2abs($self, ($self->{env}->{XDG_DATA_HOME} //
		($self->{env}->{HOME} // '/nonexistent').'/.local/share')
		.'/lei/store');
}

sub _config_path ($) {
	my ($self) = @_;
	rel2abs($self, ($self->{env}->{XDG_CONFIG_HOME} //
		($self->{env}->{HOME} // '/nonexistent').'/.config')
		.'/lei/config');
}

sub cache_dir ($) {
	my ($self) = @_;
	rel2abs($self, ($self->{env}->{XDG_CACHE_HOME} //
		($self->{env}->{HOME} // '/nonexistent').'/.cache')
		.'/lei');
}

sub ale {
	my ($self) = @_;
	$self->{ale} //= do {
		require PublicInbox::LeiALE;
		PublicInbox::LeiALE->new(cache_dir($self).
					'/all_locals_ever.git');
	};
}

sub index_opt {
	# TODO: drop underscore variants everywhere, they're undocumented
	qw(fsync|sync! jobs|j=i indexlevel|L=s compact
	max_size|max-size=s sequential_shard|sequential-shard
	batch_size|batch-size=s skip-docdata)
}

# we generate shell completion + help using %CMD and %OPTDESC,
# see lei__complete() and PublicInbox::LeiHelp
# command => [ positional_args, 1-line description, Getopt::Long option spec ]
our %CMD = ( # sorted in order of importance/use:
'q' => [ '--stdin|SEARCH_TERMS...', 'search for messages matching terms',
	'stdin|', # /|\z/ must be first for lone dash
	qw(save-as=s output|mfolder|o=s format|f=s dedupe|d=s threads|t+
	sort|s=s reverse|r offset=i remote! local! external! pretty
	include|I=s@ exclude=s@ only=s@ jobs|j=s globoff|g augment|a
	import-remote! import-before! lock=s@ rsyncable
	alert=s@ mua=s no-torsocks torsocks=s verbose|v+ quiet|q C=s@),
	PublicInbox::LeiQuery::curl_opt(), opt_dash('limit|n=i', '[0-9]+') ],

'show' => [ 'MID|OID', 'show a given object (Message-ID or object ID)',
	qw(type=s solve! format|f=s dedupe|d=s threads|t remote local! C=s@),
	pass_through('git show') ],

'add-external' => [ 'LOCATION',
	'add/set priority of a publicinbox|extindex for extra matches',
	qw(boost=i c=s@ mirror=s no-torsocks torsocks=s inbox-version=i),
	qw(quiet|q verbose|v+ C=s@),
	index_opt(), PublicInbox::LeiQuery::curl_opt() ],
'ls-external' => [ '[FILTER]', 'list publicinbox|extindex locations',
	qw(format|f=s z|0 globoff|g invert-match|v local remote C=s@) ],
'forget-external' => [ 'LOCATION...|--prune',
	'exclude further results from a publicinbox|extindex',
	qw(prune quiet|q C=s@) ],

'ls-query' => [ '[FILTER...]', 'list saved search queries',
		qw(name-only format|f=s C=s@) ],
'rm-query' => [ 'QUERY_NAME', 'remove a saved search', qw(C=s@) ],
'mv-query' => [ qw(OLD_NAME NEW_NAME), 'rename a saved search', qw(C=s@) ],

'plonk' => [ '--threads|--from=IDENT',
	'exclude mail matching From: or threads from non-Message-ID searches',
	qw(stdin| threads|t from|f=s mid=s oid=s C=s@) ],
'mark' => [ 'MESSAGE_FLAGS...',
	'set/unset keywords on message(s) from stdin',
	qw(stdin| oid=s exact by-mid|mid:s C=s@) ],
'forget' => [ '[--stdin|--oid=OID|--by-mid=MID]',
	"exclude message(s) on stdin from `q' search results",
	qw(stdin| oid=s exact by-mid|mid:s quiet|q C=s@) ],

'purge-mailsource' => [ 'LOCATION|--all',
	'remove imported messages from IMAP, Maildirs, and MH',
	qw(exact! all jobs:i indexed C=s@) ],

# code repos are used for `show' to solve blobs from patch mails
'add-coderepo' => [ 'DIRNAME', 'add or set priority of a git code repo',
	qw(boost=i C=s@) ],
'ls-coderepo' => [ '[FILTER_TERMS...]',
		'list known code repos', qw(format|f=s z C=s@) ],
'forget-coderepo' => [ 'DIRNAME',
	'stop using repo to solve blobs from patches',
	qw(prune C=s@) ],

'add-watch' => [ 'LOCATION', 'watch for new messages and flag changes',
	qw(import! kw|keywords|flags! interval=s recursive|r
	exclude=s include=s C=s@) ],
'ls-watch' => [ '[FILTER...]', 'list active watches with numbers and status',
		qw(format|f=s z C=s@) ],
'pause-watch' => [ '[WATCH_NUMBER_OR_FILTER]', qw(all local remote C=s@) ],
'resume-watch' => [ '[WATCH_NUMBER_OR_FILTER]', qw(all local remote C=s@) ],
'forget-watch' => [ '{WATCH_NUMBER|--prune}', 'stop and forget a watch',
	qw(prune C=s@) ],

'import' => [ 'LOCATION...|--stdin',
	'one-time import/update from URL or filesystem',
	qw(stdin| offset=i recursive|r exclude=s include|I=s
	lock=s@ in-format|F=s kw|keywords|flags! C=s@),
	],
'convert' => [ 'LOCATION...|--stdin',
	'one-time conversion from URL or filesystem to another format',
	qw(stdin| in-format|F=s out-format|f=s output|mfolder|o=s quiet|q
	lock=s@ kw|keywords|flags! C=s@),
	],
'p2q' => [ 'FILE|COMMIT_OID|--stdin',
	"use a patch to generate a query for `lei q --stdin'",
	qw(stdin| want|w=s@ uri debug) ],
'config' => [ '[...]', sub {
		'git-config(1) wrapper for '._config_path($_[0]);
	}, qw(config-file|system|global|file|f=s), # for conflict detection
	 qw(C=s@), pass_through('git config') ],
'init' => [ '[DIRNAME]', sub {
	"initialize storage, default: ".store_path($_[0]);
	}, qw(quiet|q C=s@) ],
'daemon-kill' => [ '[-SIGNAL]', 'signal the lei-daemon',
	# "-C DIR" conflicts with -CHLD, here, and chdir makes no sense, here
	opt_dash('signal|s=s', '[0-9]+|(?:[A-Z][A-Z0-9]+)') ],
'daemon-pid' => [ '', 'show the PID of the lei-daemon' ],
'help' => [ '[SUBCOMMAND]', 'show help' ],

# XXX do we need this?
# 'git' => [ '[ANYTHING...]', 'git(1) wrapper', pass_through('git') ],

'reorder-local-store-and-break-history' => [ '[REFNAME]',
	'rewrite git history in an attempt to improve compression',
	qw(gc! C=s@) ],

# internal commands are prefixed with '_'
'_complete' => [ '[...]', 'internal shell completion helper',
		pass_through('everything') ],
); # @CMD

# switch descriptions, try to keep consistent across commands
# $spec: Getopt::Long option specification
# $spec => [@ALLOWED_VALUES (default is first), $description],
# $spec => $description
# "$SUB_COMMAND TAB $spec" => as above
my $stdin_formats = [ 'MAIL_FORMAT|eml|mboxrd|mboxcl2|mboxcl|mboxo',
			'specify message input format' ];
my $ls_format = [ 'OUT|plain|json|null', 'listing output format' ];

# we use \x{a0} (non-breaking SP) to avoid wrapping in PublicInbox::LeiHelp
my %OPTDESC = (
'help|h' => 'show this built-in help',
'C=s@' => [ 'DIR', 'chdir to specify to directory' ],
'quiet|q' => 'be quiet',
'lock=s@' => [ 'METHOD|dotlock|fcntl|flock|none',
	'mbox(5) locking method(s) to use (default: fcntl,dotlock)' ],

'globoff|g' => "do not match locations using '*?' wildcards ".
		"and\xa0'[]'\x{a0}ranges",
'verbose|v+' => 'be more verbose',
'external!' => 'do not use externals',
'solve!' => 'do not attempt to reconstruct blobs from emails',
'torsocks=s' => ['VAL|auto|no|yes',
		'whether or not to wrap git and curl commands with torsocks'],
'no-torsocks' => 'alias for --torsocks=no',
'save-as=s' => ['NAME', 'save a search terms by given name'],
'import-remote!' => 'do not memoize remote messages into local store',

'type=s' => [ 'any|mid|git', 'disambiguate type' ],

'dedupe|d=s' => ['STRATEGY|content|oid|mid|none',
		'deduplication strategy'],
'threads|t+' =>
	'return all messages in the same threads as the actual match(es)',

'want|w=s@' => [ 'PREFIX|dfpost|dfn', # common ones in help...
		'search prefixes to extract (default: dfpost7)' ],

'alert=s@' => ['CMD,:WINCH,:bell,<any command>',
	'run command(s) or perform ops when done writing to output ' .
	'(default: ":WINCH,:bell" with --mua and Maildir/IMAP output, ' .
	'nothing otherwise)' ],

'augment|a' => 'augment --output destination instead of clobbering',

'output|mfolder|o=s' => [ 'MFOLDER',
	"destination (e.g.\xa0`/path/to/Maildir', ".
	"or\xa0`-'\x{a0}for\x{a0}stdout)" ],
'mua=s' => [ 'CMD',
	"MUA to run on --output Maildir or mbox (e.g.\xa0`mutt\xa0-f\xa0%f')" ],

'inbox-version=i' => [ 'NUM|1|2',
		'force a public-inbox version with --mirror'],
'mirror=s' => [ 'URL', 'mirror a public-inbox'],

# public-inbox-index options
'fsync!' => 'speed up indexing after --mirror, risk index corruption',
'compact' => 'run compact index after mirroring',
'indexlevel|L=s' => [ 'LEVEL|full|medium|basic',
	"indexlevel with --mirror (default: full)" ],
'max_size|max-size=s' => [ 'SIZE',
	'do not index messages larger than SIZE (default: infinity)' ],
'batch_size|batch-size=s' => [ 'SIZE',
	'flush changes to OS after given number of bytes (default: 1m)' ],
'sequential_shard|sequential-shard' =>
	'index Xapian shards sequentially for slow storage',
'skip-docdata' =>
	'drop compatibility w/ public-inbox <1.6 to save ~1.5% space',

'format|f=s	q' => [
	'OUT|maildir|mboxrd|mboxcl2|mboxcl|mboxo|html|json|jsonl|concatjson',
		'specify output format, default depends on --output'],
'exclude=s@	q' => [ 'LOCATION',
		'exclude specified external(s) from search' ],
'include|I=s@	q' => [ 'LOCATION',
		'include specified external(s) in search' ],
'only=s@	q' => [ 'LOCATION',
		'only use specified external(s) for search' ],
'jobs=s	q' => [ '[SEARCH_JOBS][,WRITER_JOBS]',
		'control number of search and writer jobs' ],
'jobs|j=i	add-external' => 'set parallelism when indexing after --mirror',

'in-format|F=s' => $stdin_formats,
'format|f=s	ls-query' => $ls_format,
'format|f=s	ls-external' => $ls_format,

'limit|n=i@' => ['NUM', 'limit on number of matches (default: 10000)' ],
'offset=i' => ['OFF', 'search result offset (default: 0)'],

'sort|s=s' => [ 'VAL|received|relevance|docid',
		"order of results is `--output'-dependent"],
'reverse|r' => 'reverse search results', # like sort(1)

'boost=i' => 'increase/decrease priority of results (default: 0)',

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

'kw|keywords|flags!' => 'disable/enable importing flags',

# xargs, env, use "-0", git(1) uses "-z".  We support z|0 everywhere
'z|0' => 'use NUL \\0 instead of newline (CR) to delimit lines',

'signal|s=s' => [ 'SIG', 'signal to send lei-daemon (default: TERM)' ],
); # %OPTDESC

my %CONFIG_KEYS = (
	'leistore.dir' => 'top-level storage location',
);

my @WQ_KEYS = qw(lxs l2m imp mrr cnv p2q); # internal workers

# pronounced "exit": x_it(1 << 8) => exit(1); x_it(13) => SIGPIPE
sub x_it ($$) {
	my ($self, $code) = @_;
	# make sure client sees stdout before exit
	$self->{1}->autoflush(1) if $self->{1};
	dump_and_clear_log();
	if (my $s = $self->{pkt_op_p} // $self->{sock}) {
		send($s, "x_it $code", MSG_EOR);
	} elsif ($self->{oneshot}) {
		# don't want to end up using $? from child processes
		for my $f (@WQ_KEYS) {
			my $wq = delete $self->{$f} or next;
			$wq->DESTROY;
		}
		# cleanup anything that has tempfiles or open file handles
		%PATH2CFG = ();
		delete @$self{qw(ovv dedupe sto cfg)};
		if (my $signum = ($code & 127)) { # usually SIGPIPE (13)
			$SIG{PIPE} = 'DEFAULT'; # $SIG{$signum} doesn't work
			kill $signum, $$;
			sleep(1) while 1; # wait for signal
		} else {
			$quit->($code >> 8);
		}
	} # else ignore if client disconnected
}

sub err ($;@) {
	my $self = shift;
	my $err = $self->{2} // ($self->{pgr} // [])->[2] // *STDERR{GLOB};
	my @eor = (substr($_[-1]//'', -1, 1) eq "\n" ? () : ("\n"));
	print $err @_, @eor and return;
	my $old_err = delete $self->{2};
	close($old_err) if $! == EPIPE && $old_err;
	$err = $self->{2} = ($self->{pgr} // [])->[2] // *STDERR{GLOB};
	print $err @_, @eor or print STDERR @_, @eor;
}

sub qerr ($;@) { $_[0]->{opt}->{quiet} or err(shift, @_) }

sub fail_handler ($;$$) {
	my ($lei, $code, $io) = @_;
	for my $f (@WQ_KEYS) {
		my $wq = delete $lei->{$f} or next;
		$wq->wq_wait_old(undef, $lei) if $wq->wq_kill_old; # lei-daemon
	}
	close($io) if $io; # needed to avoid warnings on SIGPIPE
	x_it($lei, $code // (1 << 8));
}

sub sigpipe_handler { # handles SIGPIPE from @WQ_KEYS workers
	fail_handler($_[0], 13, delete $_[0]->{1});
}

# PublicInbox::OnDestroy callback for SIGINT to take out the entire pgid
sub sigint_reap {
	my ($pgid) = @_;
	dwaitpid($pgid) if kill('-INT', $pgid);
}

sub fail ($$;$) {
	my ($self, $buf, $exit_code) = @_;
	err($self, $buf) if defined $buf;
	# calls fail_handler:
	send($self->{pkt_op_p}, '!', MSG_EOR) if $self->{pkt_op_p};
	x_it($self, ($exit_code // 1) << 8);
	undef;
}

sub check_input_format ($;$) {
	my ($self, $files) = @_;
	my $opt_key = 'in-format';
	my $fmt = $self->{opt}->{$opt_key};
	if (!$fmt) {
		my $err = $files ? "regular file(s):\n@$files" : '--stdin';
		return fail($self, "--$opt_key unset for $err");
	}
	require PublicInbox::MboxLock if $files;
	require PublicInbox::MboxReader;
	return 1 if $fmt eq 'eml';
	# XXX: should this handle {gz,bz2,xz}? that's currently in LeiToMail
	PublicInbox::MboxReader->can($fmt) or
		return fail($self, "--$opt_key=$fmt unrecognized");
	1;
}

sub out ($;@) {
	my $self = shift;
	return if print { $self->{1} // return } @_; # likely
	return note_sigpipe($self, 1) if $! == EPIPE;
	my $err = "error writing to output: $!";
	delete $self->{1};
	fail($self, $err);
}

sub puts ($;@) { out(shift, map { "$_\n" } @_) }

sub child_error { # passes non-fatal curl exit codes to user
	my ($self, $child_error, $msg) = @_; # child_error is $?
	$self->err($msg) if $msg;
	if (my $s = $self->{pkt_op_p} // $self->{sock}) {
		# send to the parent lei-daemon or to lei(1) client
		send($s, "child_error $child_error", MSG_EOR);
	} elsif (!$PublicInbox::DS::in_loop) {
		$self->{child_error} = $child_error;
	} # else noop if client disconnected
}

sub note_sigpipe { # triggers sigpipe_handler
	my ($self, $fd) = @_;
	close(delete($self->{$fd})); # explicit close silences Perl warning
	send($self->{pkt_op_p}, '|', MSG_EOR) if $self->{pkt_op_p};
	x_it($self, 13);
}

sub lei_atfork_child {
	my ($self, $persist) = @_;
	# we need to explicitly close things which are on stack
	if ($persist) {
		my @io = delete @$self{qw(0 1 2 sock)};
		unless ($self->{oneshot}) {
			close($_) for @io;
		}
	} else {
		delete $self->{0};
	}
	delete @$self{qw(cnv)};
	for (delete @$self{qw(3 old_1 au_done)}) {
		close($_) if defined($_);
	}
	if (my $op_c = delete $self->{pkt_op_c}) {
		close(delete $op_c->{sock});
	}
	if (my $pgr = delete $self->{pgr}) {
		close($_) for (@$pgr[1,2]);
	}
	close $listener if $listener;
	undef $listener;
	%PATH2CFG = ();
	undef $errors_log;
	$quit = \&CORE::exit;
	$current_lei = $persist ? undef : $self; # for SIG{__WARN__}
}

sub workers_start {
	my ($lei, $wq, $ident, $jobs, $ops) = @_;
	$ops = {
		'!' => [ $lei->can('fail_handler'), $lei ],
		'|' => [ $lei->can('sigpipe_handler'), $lei ],
		'x_it' => [ $lei->can('x_it'), $lei ],
		'child_error' => [ $lei->can('child_error'), $lei ],
		%$ops
	};
	require PublicInbox::PktOp;
	($lei->{pkt_op_c}, $lei->{pkt_op_p}) = PublicInbox::PktOp->pair($ops);
	$wq->wq_workers_start($ident, $jobs, $lei->oldset, { lei => $lei });
	delete $lei->{pkt_op_p};
	my $op = delete $lei->{pkt_op_c};
	$lei->event_step_init;
	# oneshot needs $op, daemon-mode uses DS->EventLoop to handle $op
	$lei->{oneshot} ? $op : undef;
}

sub _help {
	require PublicInbox::LeiHelp;
	PublicInbox::LeiHelp::call($_[0], $_[1], \%CMD, \%OPTDESC);
}

sub optparse ($$$) {
	my ($self, $cmd, $argv) = @_;
	# allow _complete --help to complete, not show help
	return 1 if substr($cmd, 0, 1) eq '_';
	$self->{cmd} = $cmd;
	$OPT = $self->{opt} //= {};
	my $info = $CMD{$cmd} // [ '[...]' ];
	my ($proto, undef, @spec) = @$info;
	my $glp = ref($spec[-1]) eq ref($GLP) ? pop(@spec) : $GLP;
	push @spec, qw(help|h);
	my $lone_dash;
	if ($spec[0] =~ s/\|\z//s) { # "stdin|" or "clear|" allows "-" alias
		$lone_dash = $spec[0];
		$OPT->{$spec[0]} = \(my $var);
		push @spec, '' => \$var;
	}
	$glp->getoptionsfromarray($argv, $OPT, @spec) or
		return _help($self, "bad arguments or options for $cmd");
	return _help($self) if $OPT->{help};

	push @$argv, @{$OPT->{-argv}} if defined($OPT->{-argv});

	# "-" aliases "stdin" or "clear"
	$OPT->{$lone_dash} = ${$OPT->{$lone_dash}} if defined $lone_dash;

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
		} elsif ($var =~ /\A\[-?$POS_ARG\]\z/) { # one optional arg
			$i++;
		} elsif ($var =~ /\A.+?\|/) { # required FOO|--stdin
			$inf = 1 if index($var, '...') > 0;
			my @or = split(/\|/, $var);
			my $ok;
			for my $o (@or) {
				if ($o =~ /\A--([a-z0-9\-]+)/) {
					$ok = defined($OPT->{$1});
					last if $ok;
				} elsif (defined($argv->[$i])) {
					$ok = 1;
					$i++;
					last;
				} # else continue looping
			}
			last if $ok;
			my $last = pop @or;
			$err = join(', ', @or) . " or $last must be set";
		} else {
			warn "BUG: can't parse `$var' in $proto";
		}
		last if $err;
	}
	if (!$inf && scalar(@$argv) > scalar(@args)) {
		$err //= 'too many arguments';
	}
	$err ? fail($self, "usage: lei $cmd $proto\nE: $err") : 1;
}

sub dispatch {
	my ($self, $cmd, @argv) = @_;
	local $current_lei = $self; # for __WARN__
	dump_and_clear_log("from previous run\n");
	return _help($self, 'no command given') unless defined($cmd);
	while ($cmd eq '-C') { # do not support Getopt bundling for this
		my $d = shift(@argv) // return fail($self, '-C DIRECTORY');
		push @{$self->{opt}->{C}}, $d;
		$cmd = shift(@argv) // return _help($self, 'no command given');
	}
	my $func = "lei_$cmd";
	$func =~ tr/-/_/;
	if (my $cb = __PACKAGE__->can($func)) {
		optparse($self, $cmd, \@argv) or return;
		if (my $chdir = $self->{opt}->{C}) {
			for my $d (@$chdir) {
				next if $d eq ''; # same as git(1)
				chdir $d or return fail($self, "cd $d: $!");
			}
		}
		$cb->($self, @argv);
	} elsif (grep(/\A-/, $cmd, @argv)) { # --help or -h only
		$GLP->getoptionsfromarray([$cmd, @argv], {}, qw(help|h C=s@))
			or return _help($self, 'bad arguments or options');
		_help($self);
	} else {
		fail($self, "`$cmd' is not an lei command");
	}
}

sub _lei_cfg ($;$) {
	my ($self, $creat) = @_;
	my $f = _config_path($self);
	my @st = stat($f);
	my $cur_st = @st ? pack('dd', $st[10], $st[7]) : ''; # 10:ctime, 7:size
	my ($sto, $sto_dir);
	if (my $cfg = $PATH2CFG{$f}) { # reuse existing object in common case
		return ($self->{cfg} = $cfg) if $cur_st eq $cfg->{-st};
		($sto, $sto_dir) = @$cfg{qw(-lei_store leistore.dir)};
	}
	if (!@st) {
		unless ($creat) {
			delete $self->{cfg};
			return bless {}, 'PublicInbox::Config';
		}
		my (undef, $cfg_dir, undef) = File::Spec->splitpath($f);
		-d $cfg_dir or mkpath($cfg_dir) or die "mkpath($cfg_dir): $!\n";
		open my $fh, '>>', $f or die "open($f): $!\n";
		@st = stat($fh) or die "fstat($f): $!\n";
		$cur_st = pack('dd', $st[10], $st[7]);
		qerr($self, "# $f created") if $self->{cmd} ne 'config';
	}
	my $cfg = PublicInbox::Config::git_config_dump($f);
	bless $cfg, 'PublicInbox::Config';
	$cfg->{-st} = $cur_st;
	$cfg->{'-f'} = $f;
	if ($sto && File::Spec->canonpath($sto_dir) eq
			File::Spec->canonpath($cfg->{'leistore.dir'})) {
		$cfg->{-lei_store} = $sto;
	}
	$self->{cfg} = $PATH2CFG{$f} = $cfg;
}

sub _lei_store ($;$) {
	my ($self, $creat) = @_;
	my $cfg = _lei_cfg($self, $creat);
	$cfg->{-lei_store} //= do {
		require PublicInbox::LeiStore;
		my $dir = $cfg->{'leistore.dir'};
		$dir //= $creat ? store_path($self) : return;
		PublicInbox::LeiStore->new($dir, { creat => $creat });
	};
}

sub lei_show {
	my ($self, @argv) = @_;
}

sub lei_mark {
	my ($self, @argv) = @_;
}

sub _config {
	my ($self, @argv) = @_;
	my %env = (%{$self->{env}}, GIT_CONFIG => undef);
	my $cfg = _lei_cfg($self, 1);
	my $cmd = [ qw(git config -f), $cfg->{'-f'}, @argv ];
	my %rdr = map { $_ => $self->{$_} } (0..2);
	waitpid(spawn($cmd, \%env, \%rdr), 0);
}

sub lei_config {
	my ($self, @argv) = @_;
	$self->{opt}->{'config-file'} and return fail $self,
		"config file switches not supported by `lei config'";
	_config(@_);
	x_it($self, $?) if $?;
}

sub lei_import {
	require PublicInbox::LeiImport;
	PublicInbox::LeiImport->call(@_);
}

sub lei_convert {
	require PublicInbox::LeiConvert;
	PublicInbox::LeiConvert->call(@_);
}

sub lei_p2q {
	require PublicInbox::LeiP2q;
	PublicInbox::LeiP2q->call(@_);
}

sub lei_init {
	my ($self, $dir) = @_;
	my $cfg = _lei_cfg($self, 1);
	my $cur = $cfg->{'leistore.dir'};
	$dir //= store_path($self);
	$dir = rel2abs($self, $dir);
	my @cur = stat($cur) if defined($cur);
	$cur = File::Spec->canonpath($cur // $dir);
	my @dir = stat($dir);
	my $exists = "# leistore.dir=$cur already initialized" if @dir;
	if (@cur) {
		if ($cur eq $dir) {
			_lei_store($self, 1)->done;
			return qerr($self, $exists);
		}

		# some folks like symlinks and bind mounts :P
		if (@dir && "@cur[1,0]" eq "@dir[1,0]") {
			lei_config($self, 'leistore.dir', $dir);
			_lei_store($self, 1)->done;
			return qerr($self, "$exists (as $cur)");
		}
		return fail($self, <<"");
E: leistore.dir=$cur already initialized and it is not $dir

	}
	lei_config($self, 'leistore.dir', $dir);
	_lei_store($self, 1)->done;
	$exists //= "# leistore.dir=$dir newly initialized";
	return qerr($self, $exists);
}

sub lei_daemon_pid { puts shift, $$ }

sub lei_daemon_kill {
	my ($self) = @_;
	my $sig = $self->{opt}->{signal} // 'TERM';
	kill($sig, $$) or fail($self, "kill($sig, $$): $!");
}

sub lei_help { _help($_[0]) }

# Shell completion helper.  Used by lei-completion.bash and hopefully
# other shells.  Try to do as much here as possible to avoid redundancy
# and improve maintainability.
sub lei__complete {
	my ($self, @argv) = @_; # argv = qw(lei and any other args...)
	shift @argv; # ignore "lei", the entire command is sent
	@argv or return puts $self, grep(!/^_/, keys %CMD), qw(--help -h -C);
	my $cmd = shift @argv;
	my $info = $CMD{$cmd} // do { # filter matching commands
		@argv or puts $self, grep(/\A\Q$cmd\E/, keys %CMD);
		return;
	};
	my ($proto, undef, @spec) = @$info;
	my $cur = pop @argv;
	my $re = defined($cur) ? qr/\A\Q$cur\E/ : qr/./;
	if (substr($cur // '-', 0, 1) eq '-') { # --switches
		# gross special case since the only git-config options
		# Consider moving to a table if we need more special cases
		# we use Getopt::Long for are the ones we reject, so these
		# are the ones we don't reject:
		if ($cmd eq 'config') {
			puts $self, grep(/$re/, keys %CONFIG_KEYS);
			@spec = qw(add z|null get get-all unset unset-all
				replace-all get-urlmatch
				remove-section rename-section
				name-only list|l edit|e
				get-color-name get-colorbool);
			# fall-through
		}
		# generate short/long names from Getopt::Long specs
		puts $self, grep(/$re/, qw(--help -h -C), map {
			if (s/[:=].+\z//) { # req/optional args, e.g output|o=i
			} elsif (s/\+\z//) { # verbose|v+
			} elsif (s/!\z//) {
				# negation: solve! => no-solve|solve
				s/([\w\-]+)/$1|no-$1/g
			}
			map {
				my $x = length > 1 ? "--$_" : "-$_";
				$x eq $cur ? () : $x;
			} grep(!/_/, split(/\|/, $_, -1)) # help|h
		} grep { $OPTDESC{"$_\t$cmd"} || $OPTDESC{$_} } @spec);
	} elsif ($cmd eq 'config' && !@argv && !$CONFIG_KEYS{$cur}) {
		puts $self, grep(/$re/, keys %CONFIG_KEYS);
	}

	# switch args (e.g. lei q -f mbox<TAB>)
	if (($argv[-1] // $cur // '') =~ /\A--?([\w\-]+)\z/) {
		my $opt = quotemeta $1;
		puts $self, map {
			my $v = $OPTDESC{$_};
			my @v = ref($v) ? split(/\|/, $v->[0]) : ();
			# get rid of ALL CAPS placeholder (e.g "OUT")
			# (TODO: completion for external paths)
			shift(@v) if uc($v[0]) eq $v[0];
			@v;
		} grep(/\A(?:[\w-]+\|)*$opt\b.*?(?:\t$cmd)?\z/, keys %OPTDESC);
	}
	$cmd =~ tr/-/_/;
	if (my $sub = $self->can("_complete_$cmd")) {
		puts $self, $sub->($self, @argv, $cur);
	}
	# TODO: URLs, pathnames, OIDs, MIDs, etc...  See optparse() for
	# proto parsing.
}

sub exec_buf ($$) {
	my ($argv, $env) = @_;
	my $argc = scalar @$argv;
	my $buf = 'exec '.join("\0", scalar(@$argv), @$argv);
	while (my ($k, $v) = each %$env) { $buf .= "\0$k=$v" };
	$buf;
}

sub start_mua {
	my ($self) = @_;
	my $mua = $self->{opt}->{mua} // return;
	my $mfolder = $self->{ovv}->{dst};
	my (@cmd, $replaced);
	if ($mua =~ /\A(?:mutt|mailx|mail|neomutt)\z/) {
		@cmd = ($mua, '-f');
	# TODO: help wanted: other common FOSS MUAs
	} else {
		require Text::ParseWords;
		@cmd = Text::ParseWords::shellwords($mua);
		# mutt uses '%f' for open-hook with compressed mbox, we follow
		@cmd = map { $_ eq '%f' ? ($replaced = $mfolder) : $_ } @cmd;
	}
	push @cmd, $mfolder unless defined($replaced);
	if (my $sock = $self->{sock}) { # lei(1) client process runs it
		send($sock, exec_buf(\@cmd, {}), MSG_EOR);
	} elsif ($self->{oneshot}) {
		$self->{"pid.$self.$$"}->{spawn(\@cmd)} = \@cmd;
	}
	if ($self->{lxs} && $self->{au_done}) { # kick wait_startq
		syswrite($self->{au_done}, 'q' x ($self->{lxs}->{jobs} // 0));
	}
	$self->{opt}->{quiet} = 1;
	delete $self->{-progress};
	delete $self->{opt}->{verbose};
}

sub send_exec_cmd { # tell script/lei to execute a command
	my ($self, $io, $cmd, $env) = @_;
	my $sock = $self->{sock} // die 'lei client gone';
	my $fds = [ map { fileno($_) } @$io ];
	$send_cmd->($sock, $fds, exec_buf($cmd, $env), MSG_EOR);
}

sub poke_mua { # forces terminal MUAs to wake up and hopefully notice new mail
	my ($self) = @_;
	my $alerts = $self->{opt}->{alert} // return;
	while (my $op = shift(@$alerts)) {
		if ($op eq ':WINCH') {
			# hit the process group that started the MUA
			if ($self->{sock}) {
				send($self->{sock}, '-WINCH', MSG_EOR);
			} elsif ($self->{oneshot}) {
				kill('-WINCH', $$);
			}
		} elsif ($op eq ':bell') {
			out($self, "\a");
		} elsif ($op =~ /(?<!\\),/) { # bare ',' (not ',,')
			push @$alerts, split(/(?<!\\),/, $op);
		} elsif ($op =~ m!\A([/a-z0-9A-Z].+)!) {
			my $cmd = $1; # run an arbitrary command
			require Text::ParseWords;
			$cmd = [ Text::ParseWords::shellwords($cmd) ];
			if (my $s = $self->{sock}) {
				send($s, exec_buf($cmd, {}), MSG_EOR);
			} elsif ($self->{oneshot}) {
				$self->{"pid.$self.$$"}->{spawn($cmd)} = $cmd;
			}
		} else {
			err($self, "W: unsupported --alert=$op"); # non-fatal
		}
	}
}

my %path_to_fd = ('/dev/stdin' => 0, '/dev/stdout' => 1, '/dev/stderr' => 2);
$path_to_fd{"/dev/fd/$_"} = $path_to_fd{"/proc/self/fd/$_"} for (0..2);
sub fopen {
	my ($self, $mode, $path) = @_;
	rel2abs($self, $path);
	$path =~ tr!/!/!s;
	if (defined(my $fd = $path_to_fd{$path})) {
		return $self->{$fd};
	}
	if ($path =~ m!\A/(?:dev|proc/self)/fd/[0-9]+\z!) {
		return fail($self, "cannot open $path from daemon");
	}
	open my $fh, $mode, $path or return;
	$fh;
}

# caller needs to "-t $self->{1}" to check if tty
sub start_pager {
	my ($self) = @_;
	my $fh = popen_rd([qw(git var GIT_PAGER)]);
	chomp(my $pager = <$fh> // '');
	close($fh) or warn "`git var PAGER' error: \$?=$?";
	return if $pager eq 'cat' || $pager eq '';
	my $new_env = { LESS => 'FRX', LV => '-c' };
	$new_env->{MORE} = 'FRX' if $^O eq 'freebsd';
	pipe(my ($r, $wpager)) or return warn "pipe: $!";
	my $rdr = { 0 => $r, 1 => $self->{1}, 2 => $self->{2} };
	my $pgr = [ undef, @$rdr{1, 2} ];
	my $env = $self->{env};
	if ($self->{sock}) { # lei(1) process runs it
		delete @$new_env{keys %$env}; # only set iff unset
		send_exec_cmd($self, [ @$rdr{0..2} ], [$pager], $new_env);
	} elsif ($self->{oneshot}) {
		my $cmd = [$pager];
		$self->{"pid.$self.$$"}->{spawn($cmd, $new_env, $rdr)} = $cmd;
	} else {
		die 'BUG: start_pager w/o socket';
	}
	$self->{1} = $wpager;
	$self->{2} = $wpager if -t $self->{2};
	$env->{GIT_PAGER_IN_USE} = 'true'; # we may spawn git
	$self->{pgr} = $pgr;
}

sub stop_pager {
	my ($self) = @_;
	my $pgr = delete($self->{pgr}) or return;
	$self->{2} = $pgr->[2];
	# do not restore original stdout, just close it so we error out
	close(delete($self->{1})) if $self->{1};
}

sub accept_dispatch { # Listener {post_accept} callback
	my ($sock) = @_; # ignore other
	$sock->autoflush(1);
	my $self = bless { sock => $sock }, __PACKAGE__;
	vec(my $rvec = '', fileno($sock), 1) = 1;
	select($rvec, undef, undef, 60) or
		return send($sock, 'timed out waiting to recv FDs', MSG_EOR);
	# (4096 * 33) >MAX_ARG_STRLEN
	my @fds = $recv_cmd->($sock, my $buf, 4096 * 33) or return; # EOF
	if (scalar(@fds) == 4) {
		for my $i (0..3) {
			my $fd = shift(@fds);
			open($self->{$i}, '+<&=', $fd) and next;
			send($sock, "open(+<&=$fd) (FD=$i): $!", MSG_EOR);
		}
	} elsif (!defined($fds[0])) {
		warn(my $msg = "recv_cmd failed: $!");
		return send($sock, $msg, MSG_EOR);
	} else {
		return;
	}
	$self->{2}->autoflush(1); # keep stdout buffered until x_it|DESTROY
	# $ENV_STR = join('', map { "\0$_=$ENV{$_}" } keys %ENV);
	# $buf = "$argc\0".join("\0", @ARGV).$ENV_STR."\0\0";
	substr($buf, -2, 2, '') eq "\0\0" or  # s/\0\0\z//
		return send($sock, 'request command truncated', MSG_EOR);
	my ($argc, @argv) = split(/\0/, $buf, -1);
	undef $buf;
	my %env = map { split(/=/, $_, 2) } splice(@argv, $argc);
	if (chdir($self->{3})) {
		local %ENV = %env;
		$self->{env} = \%env;
		eval { dispatch($self, @argv) };
		send($sock, $@, MSG_EOR) if $@;
	} else {
		send($sock, "fchdir: $!", MSG_EOR); # implicit close
	}
}

sub dclose {
	my ($self) = @_;
	delete $self->{-progress};
	for my $f (@WQ_KEYS) {
		my $wq = delete $self->{$f} or next;
		if ($wq->wq_kill) {
			$wq->wq_close(0, undef, $self);
		} elsif ($wq->wq_kill_old) {
			$wq->wq_wait_old(undef, $self);
		}
	}
	close(delete $self->{1}) if $self->{1}; # may reap_compress
	if (my $sto = delete $self->{sto}) {
		$sto->ipc_do('done');
	}
	$self->close if $self->{-event_init_done}; # PublicInbox::DS::close
}

# for long-running results
sub event_step {
	my ($self) = @_;
	local %ENV = %{$self->{env}};
	my $sock = $self->{sock};
	local $current_lei = $self;
	eval {
		while (my @fds = $recv_cmd->($sock, my $buf, 4096)) {
			if (scalar(@fds) == 1 && !defined($fds[0])) {
				return if $! == EAGAIN;
				next if $! == EINTR;
				last if $! == ECONNRESET;
				die "recvmsg: $!";
			}
			for my $fd (@fds) {
				open my $rfh, '+<&=', $fd;
			}
			die "unrecognized client signal: $buf";
		}
		dclose($self);
	};
	if (my $err = $@) {
		eval { $self->fail($err) };
		dclose($self);
	}
}

sub event_step_init {
	my ($self) = @_;
	return if $self->{-event_init_done}++;
	if (my $sock = $self->{sock}) { # using DS->EventLoop
		$self->SUPER::new($sock, EPOLLIN|EPOLLET);
	}
}

sub noop {}

sub oldset { $oldset }

sub dump_and_clear_log {
	if (defined($errors_log) && -s STDIN && seek(STDIN, 0, SEEK_SET)) {
		my @pfx = @_;
		unshift(@pfx, "$errors_log ") if @pfx;
		warn @pfx, do { local $/; <STDIN> };
		truncate(STDIN, 0) or warn "ftruncate ($errors_log): $!";
	}
}

# lei(1) calls this when it can't connect
sub lazy_start {
	my ($path, $errno, $narg) = @_;
	local ($errors_log, $listener);
	($errors_log) = ($path =~ m!\A(.+?/)[^/]+\z!);
	$errors_log .= 'errors.log';
	my $addr = pack_sockaddr_un($path);
	my $lk = bless { lock_path => $errors_log }, 'PublicInbox::Lock';
	$lk->lock_acquire;
	socket($listener, AF_UNIX, SOCK_SEQPACKET, 0) or die "socket: $!";
	if ($errno == ECONNREFUSED || $errno == ENOENT) {
		return if connect($listener, $addr); # another process won
		if ($errno == ECONNREFUSED && -S $path) {
			unlink($path) or die "unlink($path): $!";
		}
	} else {
		$! = $errno; # allow interpolation to stringify in die
		die "connect($path): $!";
	}
	umask(077) // die("umask(077): $!");
	bind($listener, $addr) or die "bind($path): $!";
	listen($listener, 1024) or die "listen: $!";
	$lk->lock_release;
	undef $lk;
	my @st = stat($path) or die "stat($path): $!";
	my $dev_ino_expect = pack('dd', $st[0], $st[1]); # dev+ino
	local $oldset = PublicInbox::DS::block_signals();
	if ($narg == 5) {
		$send_cmd = PublicInbox::Spawn->can('send_cmd4');
		$recv_cmd = PublicInbox::Spawn->can('recv_cmd4') // do {
			require PublicInbox::CmdIPC4;
			$send_cmd = PublicInbox::CmdIPC4->can('send_cmd4');
			PublicInbox::CmdIPC4->can('recv_cmd4');
		};
	}
	$recv_cmd or die <<"";
(Socket::MsgHdr || Inline::C) missing/unconfigured (narg=$narg);

	require PublicInbox::Listener;
	require PublicInbox::EOFpipe;
	(-p STDOUT) or die "E: stdout must be a pipe\n";
	open(STDIN, '+>>', $errors_log) or die "open($errors_log): $!";
	STDIN->autoflush(1);
	dump_and_clear_log("from previous daemon process:\n");
	POSIX::setsid() > 0 or die "setsid: $!";
	my $pid = fork // die "fork: $!";
	return if $pid;
	$0 = "lei-daemon $path";
	local %PATH2CFG;
	$listener->blocking(0);
	my $exit_code;
	my $pil = PublicInbox::Listener->new($listener, \&accept_dispatch);
	local $quit = do {
		pipe(my ($eof_r, $eof_w)) or die "pipe: $!";
		PublicInbox::EOFpipe->new($eof_r, \&noop, undef);
		sub {
			$exit_code //= shift;
			my $lis = $pil or exit($exit_code);
			# closing eof_w triggers \&noop wakeup
			$listener = $eof_w = $pil = $path = undef;
			$lis->close; # DS::close
			PublicInbox::DS->SetLoopTimeout(1000);
		};
	};
	my $sig = {
		CHLD => \&PublicInbox::DS::enqueue_reap,
		QUIT => $quit,
		INT => $quit,
		TERM => $quit,
		HUP => \&noop,
		USR1 => \&noop,
		USR2 => \&noop,
	};
	my $sigfd = PublicInbox::Sigfd->new($sig, SFD_NONBLOCK);
	local @SIG{keys %$sig} = values(%$sig) unless $sigfd;
	undef $sig;
	local $SIG{PIPE} = 'IGNORE';
	if ($sigfd) { # TODO: use inotify/kqueue to detect unlinked sockets
		undef $sigfd;
		PublicInbox::DS->SetLoopTimeout(5000);
	} else {
		# wake up every second to accept signals if we don't
		# have signalfd or IO::KQueue:
		PublicInbox::DS::sig_setmask($oldset);
		PublicInbox::DS->SetLoopTimeout(1000);
	}
	PublicInbox::DS->SetPostLoopCallback(sub {
		my ($dmap, undef) = @_;
		if (@st = defined($path) ? stat($path) : ()) {
			if ($dev_ino_expect ne pack('dd', $st[0], $st[1])) {
				warn "$path dev/ino changed, quitting\n";
				$path = undef;
			}
		} elsif (defined($path)) { # ENOENT is common
			warn "stat($path): $!, quitting ...\n" if $! != ENOENT;
			undef $path;
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

	# STDIN was redirected to /dev/null above, closing STDERR and
	# STDOUT will cause the calling `lei' client process to finish
	# reading the <$daemon> pipe.
	local $SIG{__WARN__} = sub {
		$current_lei ? err($current_lei, @_) : warn(
		  strftime('%Y-%m-%dT%H:%M:%SZ', gmtime(time))," $$ ", @_);
	};
	open STDERR, '>&STDIN' or die "redirect stderr failed: $!";
	open STDOUT, '>&STDIN' or die "redirect stdout failed: $!";
	# $daemon pipe to `lei' closed, main loop begins:
	PublicInbox::DS->EventLoop;
	exit($exit_code // 0);
}

sub busy { 1 } # prevent daemon-shutdown if client is connected

# for users w/o Socket::Msghdr installed or Inline::C enabled
sub oneshot {
	my ($main_pkg) = @_;
	my $exit = $main_pkg->can('exit'); # caller may override exit()
	local $quit = $exit if $exit;
	local %PATH2CFG;
	umask(077) // die("umask(077): $!");
	my $self = bless {
		oneshot => 1,
		0 => *STDIN{GLOB},
		1 => *STDOUT{GLOB},
		2 => *STDERR{GLOB},
		env => \%ENV
	}, __PACKAGE__;
	dispatch($self, @ARGV);
	x_it($self, $self->{child_error}) if $self->{child_error};
}

# ensures stdout hits the FS before sock disconnects so a client
# can immediately reread it
sub DESTROY {
	my ($self) = @_;
	$self->{1}->autoflush(1) if $self->{1};
	stop_pager($self);
	my $err = $?;
	my $oneshot_pids = delete $self->{"pid.$self.$$"} or return;
	waitpid($_, 0) for keys %$oneshot_pids;
	$? = $err if $err; # preserve ->fail or ->x_it code
}

1;
