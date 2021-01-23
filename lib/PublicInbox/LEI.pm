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
use Errno qw(EAGAIN EINTR ECONNREFUSED ENOENT ECONNRESET);
use POSIX ();
use IO::Handle ();
use Fcntl qw(SEEK_SET);
use Sys::Syslog qw(syslog openlog);
use PublicInbox::Config;
use PublicInbox::Syscall qw(SFD_NONBLOCK EPOLLIN EPOLLET);
use PublicInbox::Sigfd;
use PublicInbox::DS qw(now dwaitpid);
use PublicInbox::Spawn qw(spawn popen_rd);
use PublicInbox::OnDestroy;
use Text::Wrap qw(wrap);
use File::Path qw(mkpath);
use File::Spec;
our $quit = \&CORE::exit;
our ($current_lei, $errors_log, $listener);
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

sub _store_path ($) {
	my ($env) = @_;
	File::Spec->rel2abs(($env->{XDG_DATA_HOME} //
		($env->{HOME} // '/nonexistent').'/.local/share')
		.'/lei/store', $env->{PWD});
}

sub _config_path ($) {
	my ($env) = @_;
	File::Spec->rel2abs(($env->{XDG_CONFIG_HOME} //
		($env->{HOME} // '/nonexistent').'/.config')
		.'/lei/config', $env->{PWD});
}

# TODO: generate shell completion + help using %CMD and %OPTDESC
# command => [ positional_args, 1-line description, Getopt::Long option spec ]
our %CMD = ( # sorted in order of importance/use:
'q' => [ 'SEARCH_TERMS...', 'search for messages matching terms', qw(
	save-as=s output|mfolder|o=s format|f=s dedupe|d=s thread|t augment|a
	sort|s=s reverse|r offset=i remote local! external! pretty mua-cmd=s
	torsocks=s no-torsocks verbose|v since|after=s until|before=s),
	PublicInbox::LeiQuery::curl_opt(), opt_dash('limit|n=i', '[0-9]+') ],

'show' => [ 'MID|OID', 'show a given object (Message-ID or object ID)',
	qw(type=s solve! format|f=s dedupe|d=s thread|t remote local!),
	pass_through('git show') ],

'add-external' => [ 'URL_OR_PATHNAME',
	'add/set priority of a publicinbox|extindex for extra matches',
	qw(boost=i quiet|q) ],
'ls-external' => [ '[FILTER...]', 'list publicinbox|extindex locations',
	qw(format|f=s z|0 local remote quiet|q) ],
'forget-external' => [ 'URL_OR_PATHNAME...|--prune',
	'exclude further results from a publicinbox|extindex',
	qw(prune quiet|q) ],

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
	"exclude message(s) on stdin from `q' search results",
	qw(stdin| oid=s exact by-mid|mid:s quiet|q) ],

'purge-mailsource' => [ 'URL_OR_PATHNAME|--all',
	'remove imported messages from IMAP, Maildirs, and MH',
	qw(exact! all jobs:i indexed) ],

# code repos are used for `show' to solve blobs from patch mails
'add-coderepo' => [ 'PATHNAME', 'add or set priority of a git code repo',
	qw(boost=i) ],
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

'import' => [ 'URL_OR_PATHNAME|--stdin',
	'one-shot import/update from URL or filesystem',
	qw(stdin| offset=i recursive|r exclude=s include=s !flags),
	],

'config' => [ '[...]', sub {
		'git-config(1) wrapper for '._config_path($_[0]);
	}, qw(config-file|system|global|file|f=s), # for conflict detection
	pass_through('git config') ],
'init' => [ '[PATHNAME]', sub {
		'initialize storage, default: '._store_path($_[0]);
	}, qw(quiet|q) ],
'daemon-kill' => [ '[-SIGNAL]', 'signal the lei-daemon',
	opt_dash('signal|s=s', '[0-9]+|(?:[A-Z][A-Z0-9]+)') ],
'daemon-pid' => [ '', 'show the PID of the lei-daemon' ],
'help' => [ '[SUBCOMMAND]', 'show help' ],

# XXX do we need this?
# 'git' => [ '[ANYTHING...]', 'git(1) wrapper', pass_through('git') ],

'reorder-local-store-and-break-history' => [ '[REFNAME]',
	'rewrite git history in an attempt to improve compression',
	'gc!' ],

# internal commands are prefixed with '_'
'_complete' => [ '[...]', 'internal shell completion helper',
		pass_through('everything') ],
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

'dedupe|d=s' => ['STRAT|content|oid|mid|none',
		'deduplication strategy'],
'show	thread|t' => 'display entire thread a message belongs to',
'q	thread|t' =>
	'return all messages in the same thread as the actual match(es)',
'augment|a' => 'augment --output destination instead of clobbering',

'output|o=s' => [ 'DEST',
	"destination (e.g. `/path/to/Maildir', or `-' for stdout)" ],
'mua-cmd|mua=s' => [ 'COMMAND',
	"MUA to run on --output Maildir or mbox (e.g. `mutt -f %f'" ],

'show	format|f=s' => [ 'OUT|plain|raw|html|mboxrd|mboxcl2|mboxcl',
			'message/object output format' ],
'mark	format|f=s' => $stdin_formats,
'forget	format|f=s' => $stdin_formats,
'q	format|f=s' => [ 'OUT|maildir|mboxrd|mboxcl2|mboxcl|html|oid|json',
		'specify output format, default depends on --output'],
'ls-query	format|f=s' => $ls_format,
'ls-external	format|f=s' => $ls_format,

'limit|n=i@' => ['NUM', 'limit on number of matches (default: 10000)' ],
'offset=i' => ['OFF', 'search result offset (default: 0)'],

'sort|s=s' => [ 'VAL|received,relevance,docid',
		"order of results `--output'-dependent"],
'reverse|r' => [ 'reverse search results' ], # like sort(1)

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
'jobs:i' => 'set parallelism level',

# xargs, env, use "-0", git(1) uses "-z".  We support z|0 everywhere
'z|0' => 'use NUL \\0 instead of newline (CR) to delimit lines',

'signal|s=s' => [ 'SIG', 'signal to send lei-daemon (default: TERM)' ],
); # %OPTDESC

my %CONFIG_KEYS = (
	'leistore.dir' => 'top-level storage location',
);

# pronounced "exit": x_it(1 << 8) => exit(1); x_it(13) => SIGPIPE
sub x_it ($$) {
	my ($self, $code) = @_;
	# make sure client sees stdout before exit
	$self->{1}->autoflush(1) if $self->{1};
	dump_and_clear_log();
	if (my $sock = $self->{sock}) {
		send($sock, "x_it $code", MSG_EOR);
	} elsif (!($code & 127)) { # oneshot, ignore signals
		# don't want to end up using $? from child processes
		for my $f (qw(lxs l2m)) {
			my $wq = delete $self->{$f} or next;
			$wq->DESTROY;
		}
		$quit->($code >> 8);
	}
}

sub puts ($;@) { print { shift->{1} } map { "$_\n" } @_ }

sub out ($;@) { print { shift->{1} } @_ }

sub err ($;@) {
	my $self = shift;
	my $err = $self->{2} // ($self->{pgr} // [])->[2] // *STDERR{IO};
	print $err @_, (substr($_[-1], -1, 1) eq "\n" ? () : "\n");
}

sub qerr ($;@) { $_[0]->{opt}->{quiet} or err(shift, @_) }

sub fail ($$;$) {
	my ($self, $buf, $exit_code) = @_;
	err($self, $buf);
	x_it($self, ($exit_code // 1) << 8);
	undef;
}

sub child_error { # passes non-fatal curl exit codes to user
	my ($self, $child_error) = @_; # child_error is $?
	if (my $sock = $self->{sock}) { # send to lei(1) client
		send($sock, "child_error $child_error", MSG_EOR);
	} else { # oneshot
		$self->{child_error} = $child_error;
	}
	undef;
}

sub atfork_prepare_wq {
	my ($self, $wq) = @_;
	my $tcafc = $wq->{-ipc_atfork_child_close} //= [ $listener // () ];
	if (my $sock = $self->{sock}) {
		push @$tcafc, @$self{qw(0 1 2)}, $sock;
	}
	if (my $pgr = $self->{pgr}) {
		push @$tcafc, @$pgr[1,2];
	}
	if (my $old_1 = $self->{old_1}) {
		push @$tcafc, $old_1;
	}
	for my $f (qw(lxs l2m)) {
		my $ipc = $self->{$f} or next;
		push @$tcafc, grep { defined }
				@$ipc{qw(-wq_s1 -wq_s2 -ipc_req -ipc_res)};
	}
}

# usage: my %sig = $lei->atfork_child_wq($wq);
#	 local @SIG{keys %sig} = values %sig;
sub atfork_child_wq {
	my ($self, $wq) = @_;
	my ($sock, $l2m_wq_s1);
	(@$self{qw(0 1 2)}, $sock, $l2m_wq_s1) = delete(@$wq{0..4});
	$self->{sock} = $sock if -S $sock;
	$self->{l2m}->{-wq_s1} = $l2m_wq_s1 if $l2m_wq_s1 && -S $l2m_wq_s1;
	%PATH2CFG = ();
	undef $errors_log;
	$quit = \&CORE::exit;
	(__WARN__ => sub { err($self, @_) },
	PIPE => sub {
		$self->x_it(13); # SIGPIPE = 13
		# we need to close explicitly to avoid Perl warning on SIGPIPE
		for my $i (1, 2) {
			next unless $self->{$i} && (-p $self->{$i} || -S _);
			close(delete $self->{$i});
		}
		# trigger the LeiXSearch $done OpPipe:
		syswrite($self->{0}, '!') if $self->{0} && -p $self->{0};
		$SIG{PIPE} = 'DEFAULT';
		die bless(\"$_[0]", 'PublicInbox::SIGPIPE'),
	});
}

# usage: ($lei, @io) = $lei->atfork_parent_wq($wq);
sub atfork_parent_wq {
	my ($self, $wq) = @_;
	my $env = delete $self->{env}; # env is inherited at fork
	my $ret = bless { %$self }, ref($self);
	if (my $dedupe = delete $ret->{dedupe}) {
		$ret->{dedupe} = $wq->deep_clone($dedupe);
	}
	$self->{env} = $env;
	delete @$ret{qw(-lei_store cfg old_1 pgr lxs)}; # keep l2m
	my @io = delete @$ret{0..2};
	$io[3] = delete($ret->{sock}) // $io[2];
	my $l2m = $ret->{l2m};
	if ($l2m && $l2m != $wq) { # $wq == lxs
		$io[4] = $l2m->{-wq_s1} if $l2m->{-wq_s1};
		$l2m->wq_close(1);
	}
	($ret, @io);
}

sub _help ($;$) {
	my ($self, $errmsg) = @_;
	my $cmd = $self->{cmd} // 'COMMAND';
	my @info = @{$CMD{$cmd} // [ '...', '...' ]};
	my @top = ($cmd, shift(@info) // ());
	my $cmd_desc = shift(@info);
	$cmd_desc = $cmd_desc->($self->{env}) if ref($cmd_desc) eq 'CODE';
	my @opt_desc;
	my $lpad = 2;
	for my $sw (grep { !ref } @info) { # ("prio=s", "z", $GLP_PASS)
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
	print { $self->{$errmsg ? 2 : 1} } $msg;
	x_it($self, $errmsg ? 1 << 8 : 0); # stderr => failure
	undef;
}

sub optparse ($$$) {
	my ($self, $cmd, $argv) = @_;
	$self->{cmd} = $cmd;
	$OPT = $self->{opt} = {};
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
			my @or = split(/\|/, $var);
			my $ok;
			for my $o (@or) {
				if ($o =~ /\A--([a-z0-9\-]+)/) {
					$ok = defined($OPT->{$1});
					last;
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
	my $func = "lei_$cmd";
	$func =~ tr/-/_/;
	if (my $cb = __PACKAGE__->can($func)) {
		optparse($self, $cmd, \@argv) or return;
		$cb->($self, @argv);
	} elsif (grep(/\A-/, $cmd, @argv)) { # --help or -h only
		my $opt = {};
		$GLP->getoptionsfromarray([$cmd, @argv], $opt, qw(help|h)) or
			return _help($self, 'bad arguments or options');
		_help($self);
	} else {
		fail($self, "`$cmd' is not an lei command");
	}
}

sub _lei_cfg ($;$) {
	my ($self, $creat) = @_;
	my $f = _config_path($self->{env});
	my @st = stat($f);
	my $cur_st = @st ? pack('dd', $st[10], $st[7]) : ''; # 10:ctime, 7:size
	if (my $cfg = $PATH2CFG{$f}) { # reuse existing object in common case
		return ($self->{cfg} = $cfg) if $cur_st eq $cfg->{-st};
	}
	if (!@st) {
		unless ($creat) {
			delete $self->{cfg};
			return;
		}
		my (undef, $cfg_dir, undef) = File::Spec->splitpath($f);
		-d $cfg_dir or mkpath($cfg_dir) or die "mkpath($cfg_dir): $!\n";
		open my $fh, '>>', $f or die "open($f): $!\n";
		@st = stat($fh) or die "fstat($f): $!\n";
		$cur_st = pack('dd', $st[10], $st[7]);
		qerr($self, "I: $f created") if $self->{cmd} ne 'config';
	}
	my $cfg = PublicInbox::Config::git_config_dump($f);
	$cfg->{-st} = $cur_st;
	$cfg->{'-f'} = $f;
	$self->{cfg} = $PATH2CFG{$f} = $cfg;
}

sub _lei_store ($;$) {
	my ($self, $creat) = @_;
	my $cfg = _lei_cfg($self, $creat);
	$cfg->{-lei_store} //= do {
		require PublicInbox::LeiStore;
		my $dir = $cfg->{'leistore.dir'};
		$dir //= _store_path($self->{env}) if $creat;
		return unless $dir;
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
	my $env = $self->{env};
	delete local $env->{GIT_CONFIG};
	delete local $ENV{GIT_CONFIG};
	my $cfg = _lei_cfg($self, 1);
	my $cmd = [ qw(git config -f), $cfg->{'-f'}, @argv ];
	my %rdr = map { $_ => $self->{$_} } (0..2);
	waitpid(spawn($cmd, $env, \%rdr), 0);
}

sub lei_config {
	my ($self, @argv) = @_;
	$self->{opt}->{'config-file'} and return fail $self,
		"config file switches not supported by `lei config'";
	_config(@_);
	x_it($self, $?) if $?;
}

sub lei_init {
	my ($self, $dir) = @_;
	my $cfg = _lei_cfg($self, 1);
	my $cur = $cfg->{'leistore.dir'};
	my $env = $self->{env};
	$dir //= _store_path($env);
	$dir = File::Spec->rel2abs($dir, $env->{PWD}); # PWD is symlink-aware
	my @cur = stat($cur) if defined($cur);
	$cur = File::Spec->canonpath($cur // $dir);
	my @dir = stat($dir);
	my $exists = "I: leistore.dir=$cur already initialized" if @dir;
	if (@cur) {
		if ($cur eq $dir) {
			_lei_store($self, 1)->done;
			return qerr($self, $exists);
		}

		# some folks like symlinks and bind mounts :P
		if (@dir && "$cur[0] $cur[1]" eq "$dir[0] $dir[1]") {
			lei_config($self, 'leistore.dir', $dir);
			_lei_store($self, 1)->done;
			return qerr($self, "$exists (as $cur)");
		}
		return fail($self, <<"");
E: leistore.dir=$cur already initialized and it is not $dir

	}
	lei_config($self, 'leistore.dir', $dir);
	_lei_store($self, 1)->done;
	$exists //= "I: leistore.dir=$dir newly initialized";
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
	@argv or return puts $self, grep(!/^_/, keys %CMD), qw(--help -h);
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
		# TODO: arg support
		puts $self, grep(/$re/, map { # generate short/long names
			my $eq = '';
			if (s/=.+\z//) { # required arg, e.g. output|o=i
				$eq = '=';
			} elsif (s/:.+\z//) { # optional arg, e.g. mid:s
			} else { # negation: solve! => no-solve|solve
				s/\A(.+)!\z/no-$1|$1/;
			}
			map {
				length > 1 ? "--$_$eq" : "-$_"
			} split(/\|/, $_, -1) # help|h
		} grep { $OPTDESC{"$cmd\t$_"} || $OPTDESC{$_} } @spec);
	} elsif ($cmd eq 'config' && !@argv && !$CONFIG_KEYS{$cur}) {
		puts $self, grep(/$re/, keys %CONFIG_KEYS);
	}
	$cmd =~ tr/-/_/;
	if (my $sub = $self->can("_complete_$cmd")) {
		puts $self, $sub->($self, @argv, $cur);
	}
	# TODO: URLs, pathnames, OIDs, MIDs, etc...  See optparse() for
	# proto parsing.
}

sub reap_exec { # dwaitpid callback
	my ($self, $pid) = @_;
	x_it($self, $?);
}

sub lei_git { # support passing through random git commands
	my ($self, @argv) = @_;
	my %rdr = map { $_ => $self->{$_} } (0..2);
	my $pid = spawn(['git', @argv], $self->{env}, \%rdr);
	dwaitpid($pid, \&reap_exec, $self);
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
	my $mua = $self->{opt}->{'mua-cmd'} // return;
	my $mfolder = $self->{ovv}->{dst};
	my (@cmd, $replaced);
	if ($mua =~ /\A(?:mutt|mailx|mail|neomutt)\z/) {
		@cmd = ($mua, '-f');
	# TODO: help wanted: other common FOSS MUAs
	} else {
		require Text::ParseWords;
		my @cmd = Text::ParseWords::shellwords($mua);
		# mutt uses '%f' for open-hook with compressed mbox, we follow
		@cmd = map { $_ eq '%f' ? ($replaced = $mfolder) : $_ } @cmd;
	}
	push @cmd, $mfolder unless defined($replaced);
	if (my $sock = $self->{sock}) { # lei(1) client process runs it
		send($sock, exec_buf(\@cmd, {}), MSG_EOR);
	} else { # oneshot
		$self->{"mua.pid.$self.$$"} = spawn(\@cmd);
	}
}

# caller needs to "-t $self->{1}" to check if tty
sub start_pager {
	my ($self) = @_;
	my $env = $self->{env};
	my $fh = popen_rd([qw(git var GIT_PAGER)], $env);
	chomp(my $pager = <$fh> // '');
	close($fh) or warn "`git var PAGER' error: \$?=$?";
	return if $pager eq 'cat' || $pager eq '';
	# TODO TIOCGWINSZ
	my $new_env = { LESS => 'FRX', LV => '-c', COLUMNS => 80 };
	$new_env->{MORE} = 'FRX' if $^O eq 'freebsd';
	pipe(my ($r, $wpager)) or return warn "pipe: $!";
	my $rdr = { 0 => $r, 1 => $self->{1}, 2 => $self->{2} };
	my $pgr = [ undef, @$rdr{1, 2}, $$ ];
	if (my $sock = $self->{sock}) { # lei(1) process runs it
		delete @$new_env{keys %$env}; # only set iff unset
		my $fds = [ map { fileno($_) } @$rdr{0..2} ];
		$send_cmd->($sock, $fds, exec_buf([$pager], $new_env), MSG_EOR);
	} else {
		$pgr->[0] = spawn([$pager], $new_env, $rdr);
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
	my $pid = $pgr->[0];
	dwaitpid($pid, undef, $self->{sock}) if $pid && $pgr->[3] == $$;
}

sub accept_dispatch { # Listener {post_accept} callback
	my ($sock) = @_; # ignore other
	$sock->autoflush(1);
	my $self = bless { sock => $sock }, __PACKAGE__;
	vec(my $rvec = '', fileno($sock), 1) = 1;
	select($rvec, undef, undef, 1) or
		return send($sock, 'timed out waiting to recv FDs', MSG_EOR);
	my @fds = $recv_cmd->($sock, my $buf, 4096 * 33); # >MAX_ARG_STRLEN
	if (scalar(@fds) == 4) {
		my $i = 0;
		for my $rdr (qw(<&= >&= >&= <&=)) {
			my $fd = shift(@fds);
			open($self->{$i++}, $rdr, $fd) and next;
			send($sock, "open($rdr$fd) (FD=$i): $!", MSG_EOR);
		}
	} else {
		return send($sock, "recv_cmd failed: $!", MSG_EOR);
	}
	$self->{2}->autoflush(1); # keep stdout buffered until x_it|DESTROY
	# $ENV_STR = join('', map { "\0$_=$ENV{$_}" } keys %ENV);
	# $buf = "$$\0$argc\0".join("\0", @ARGV).$ENV_STR."\0\0";
	substr($buf, -2, 2, '') eq "\0\0" or  # s/\0\0\z//
		return send($sock, 'request command truncated', MSG_EOR);
	my ($argc, @argv) = split(/\0/, $buf, -1);
	undef $buf;
	my %env = map { split(/=/, $_, 2) } splice(@argv, $argc);
	if (chdir(delete($self->{3}))) {
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
	for my $f (qw(lxs l2m)) {
		my $wq = delete $self->{$f} or next;
		if ($wq->wq_kill) {
			$self->wq_close
		} elsif ($wq->wq_kill_old) {
			$wq->wq_wait_old;
		}
	}
	close(delete $self->{1}) if $self->{1}; # may reap_compress
	$self->close if $self->{sock}; # PublicInbox::DS::close
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
	if (my $sock = $self->{sock}) { # using DS->EventLoop
		$sock->blocking(0);
		$self->SUPER::new($sock, EPOLLIN|EPOLLET);
	}
}

sub noop {}

our $oldset; sub oldset { $oldset }

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
	if ($errno == ECONNREFUSED) {
		unlink($path) or die "unlink($path): $!";
	} elsif ($errno != ENOENT) {
		$! = $errno; # allow interpolation to stringify in die
		die "connect($path): $!";
	}
	umask(077) // die("umask(077): $!");
	local $listener;
	socket($listener, AF_UNIX, SOCK_SEQPACKET, 0) or die "socket: $!";
	bind($listener, pack_sockaddr_un($path)) or die "bind($path): $!";
	listen($listener, 1024) or die "listen: $!";
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
	local $errors_log;
	($errors_log) = ($path =~ m!\A(.+?/)[^/]+\z!);
	$errors_log .= 'errors.log';
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

	# STDIN was redirected to /dev/null above, closing STDERR and
	# STDOUT will cause the calling `lei' client process to finish
	# reading the <$daemon> pipe.
	openlog($path, 'pid', 'user');
	local $SIG{__WARN__} = sub {
		$current_lei ? err($current_lei, @_) : syslog('warning', "@_");
	};
	my $on_destroy = PublicInbox::OnDestroy->new($$, sub {
		syslog('crit', "$@") if $@;
	});
	open STDERR, '>&STDIN' or die "redirect stderr failed: $!";
	open STDOUT, '>&STDIN' or die "redirect stdout failed: $!";
	# $daemon pipe to `lei' closed, main loop begins:
	PublicInbox::DS->EventLoop;
	@$on_destroy = (); # cancel on_destroy if we get here
	exit($exit_code // 0);
}

# for users w/o Socket::Msghdr installed or Inline::C enabled
sub oneshot {
	my ($main_pkg) = @_;
	my $exit = $main_pkg->can('exit'); # caller may override exit()
	local $quit = $exit if $exit;
	local %PATH2CFG;
	umask(077) // die("umask(077): $!");
	my $self = bless {
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
	if (my $mua_pid = delete $self->{"mua.pid.$self.$$"}) {
		waitpid($mua_pid, 0);
	}
}

1;
