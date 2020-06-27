# Copyright (C) 2016-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# ref: https://cr.yp.to/proto/maildir.html
#	http://wiki2.dovecot.org/MailboxFormat/Maildir
package PublicInbox::WatchMaildir;
use strict;
use warnings;
use PublicInbox::Eml;
use PublicInbox::InboxWritable;
use PublicInbox::Filter::Base qw(REJECT);
use PublicInbox::Spamcheck;
use PublicInbox::Sigfd;
use PublicInbox::DS qw(now);
use POSIX qw(_exit);
*mime_from_path = \&PublicInbox::InboxWritable::mime_from_path;

sub compile_watchheaders ($) {
	my ($ibx) = @_;
	my $watch_hdrs = [];
	if (my $whs = $ibx->{watchheader}) {
		for (@$whs) {
			my ($k, $v) = split(/:/, $_, 2);
			# XXX should this be case-insensitive?
			# Or, mutt-style, case-sensitive iff
			# a capital letter exists?
			push @$watch_hdrs, [ $k, qr/\Q$v\E/ ];
		}
	}
	if (my $list_ids = $ibx->{listid}) {
		for (@$list_ids) {
			# RFC2919 section 6 stipulates
			# "case insensitive equality"
			my $re = qr/<[ \t]*\Q$_\E[ \t]*>/i;
			push @$watch_hdrs, ['List-Id', $re ];
		}
	}
	$ibx->{-watchheaders} = $watch_hdrs if scalar @$watch_hdrs;
}

sub new {
	my ($class, $config) = @_;
	my (%mdmap, $spamc);
	my %imap; # url => [inbox objects] or 'watchspam'

	# "publicinboxwatch" is the documented namespace
	# "publicinboxlearn" is legacy but may be supported
	# indefinitely...
	foreach my $pfx (qw(publicinboxwatch publicinboxlearn)) {
		my $k = "$pfx.watchspam";
		defined(my $dirs = $config->{$k}) or next;
		$dirs = PublicInbox::Config::_array($dirs);
		for my $dir (@$dirs) {
			if (is_maildir($dir)) {
				# skip "new", no MUA has seen it, yet.
				$mdmap{"$dir/cur"} = 'watchspam';
			} elsif (my $url = imap_url($dir)) {
				$imap{$url} = 'watchspam';
			} else {
				warn "unsupported $k=$dir\n";
			}
		}
	}

	my $k = 'publicinboxwatch.spamcheck';
	my $default = undef;
	my $spamcheck = PublicInbox::Spamcheck::get($config, $k, $default);
	$spamcheck = _spamcheck_cb($spamcheck) if $spamcheck;

	$config->each_inbox(sub {
		# need to make all inboxes writable for spam removal:
		my $ibx = $_[0] = PublicInbox::InboxWritable->new($_[0]);

		my $watches = $ibx->{watch} or return;
		$watches = PublicInbox::Config::_array($watches);
		for my $watch (@$watches) {
			if (is_maildir($watch)) {
				compile_watchheaders($ibx);
				my ($new, $cur) = ("$watch/new", "$watch/cur");
				my $cur_dst = $mdmap{$cur} //= [];
				return if is_watchspam($cur, $cur_dst, $ibx);
				push @{$mdmap{$new} //= []}, $ibx;
				push @$cur_dst, $ibx;
			} elsif (my $url = imap_url($watch)) {
				return if is_watchspam($url, $imap{$url}, $ibx);
				compile_watchheaders($ibx);
				push @{$imap{$url} ||= []}, $ibx;
			} else {
				warn "watch unsupported: $k=$watch\n";
			}
		}
	});

	my $mdre;
	if (scalar keys %mdmap) {
		$mdre = join('|', map { quotemeta($_) } keys %mdmap);
		$mdre = qr!\A($mdre)/!;
	}
	return unless $mdre || scalar(keys %imap);
	bless {
		spamcheck => $spamcheck,
		mdmap => \%mdmap,
		mdre => $mdre,
		config => $config,
		imap => scalar keys %imap ? \%imap : undef,
		importers => {},
		opendirs => {}, # dirname => dirhandle (in progress scans)
		ops => [], # 'quit', 'full'
	}, $class;
}

sub _done_for_now {
	my ($self) = @_;
	my $importers = $self->{importers};
	foreach my $im (values %$importers) {
		$im->done;
	}
}

sub remove_eml_i { # each_inbox callback
	my ($ibx, $arg) = @_;
	my ($self, $eml, $loc) = @$arg;
	eval {
		my $im = _importer_for($self, $ibx);
		$im->remove($eml, 'spam');
		if (my $scrub = $ibx->filter($im)) {
			my $scrubbed = $scrub->scrub($eml, 1);
			$scrubbed or return;
			$scrubbed == REJECT() and return;
			$im->remove($scrubbed, 'spam');
		}
	};
	warn "error removing spam at: $loc from $ibx->{name}: $@\n" if $@;
}

sub _remove_spam {
	my ($self, $path) = @_;
	# path must be marked as (S)een
	$path =~ /:2,[A-R]*S[T-Za-z]*\z/ or return;
	my $eml = mime_from_path($path) or return;
	$self->{config}->each_inbox(\&remove_eml_i, [ $self, $eml, $path ]);
}

sub import_eml ($$$) {
	my ($self, $ibx, $eml) = @_;
	my $im = _importer_for($self, $ibx);

	# any header match means it's eligible for the inbox:
	if (my $watch_hdrs = $ibx->{-watchheaders}) {
		my $ok;
		my $hdr = $eml->header_obj;
		for my $wh (@$watch_hdrs) {
			my @v = $hdr->header_raw($wh->[0]);
			$ok = grep(/$wh->[1]/, @v) and last;
		}
		return unless $ok;
	}

	if (my $scrub = $ibx->filter($im)) {
		my $ret = $scrub->scrub($eml) or return;
		$ret == REJECT() and return;
		$eml = $ret;
	}
	$im->add($eml, $self->{spamcheck});
}

sub _try_path {
	my ($self, $path) = @_;
	return unless PublicInbox::InboxWritable::is_maildir_path($path);
	if ($path !~ $self->{mdre}) {
		warn "unrecognized path: $path\n";
		return;
	}
	my $inboxes = $self->{mdmap}->{$1};
	unless ($inboxes) {
		warn "unmappable dir: $1\n";
		return;
	}
	if (!ref($inboxes) && $inboxes eq 'watchspam') {
		return _remove_spam($self, $path);
	}

	my $warn_cb = $SIG{__WARN__} || sub { print STDERR @_ };
	local $SIG{__WARN__} = sub {
		$warn_cb->("path: $path\n");
		$warn_cb->(@_);
	};
	foreach my $ibx (@$inboxes) {
		my $eml = mime_from_path($path) or next;
		import_eml($self, $ibx, $eml);
	}
}

sub quit {
	my ($self) = @_;
	$self->{quit} = 1;
	%{$self->{opendirs}} = ();
	_done_for_now($self);
	if (my $imap_pid = $self->{-imap_pid}) {
		kill('QUIT', $imap_pid);
	}
	for (qw(idle_pids poll_pids)) {
		my $pids = $self->{$_} or next;
		kill('QUIT', $_) for (keys %$pids);
	}
	if (my $idle_mic = $self->{idle_mic}) {
		eval { $idle_mic->done };
		if ($@) {
			warn "IDLE DONE error: $@\n";
			eval { $idle_mic->disconnect };
			warn "IDLE LOGOUT error: $@\n" if $@;
		}
	}
}

sub watch_fs_init ($) {
	my ($self) = @_;
	my $done = sub {
		delete $self->{done_timer};
		_done_for_now($self);
	};
	my $cb = sub {
		_try_path($self, $_[0]->fullname);
		$self->{done_timer} //= PublicInbox::DS::requeue($done);
	};
	require PublicInbox::DirIdle;
	# inotify_create + EPOLL_CTL_ADD
	PublicInbox::DirIdle->new([keys %{$self->{mdmap}}], $cb);
}

# returns the git config section name, e.g [imap "imaps://user@example.com"]
# without the mailbox, so we can share connections between different inboxes
sub imap_section ($) {
	my ($uri) = @_;
	$uri->scheme . '://' . $uri->authority;
}

sub cfg_intvl ($$$) {
	my ($cfg, $key, $url) = @_;
	my $v = $cfg->urlmatch($key, $url) // return;
	$v =~ /\A[0-9]+(?:\.[0-9]+)?\z/s and return $v + 0;
	if (ref($v) eq 'ARRAY') {
		$v = join(', ', @$v);
		warn "W: $key has multiple values: $v\nW: $key ignored\n";
	} else {
		warn "W: $key=$v is not a numeric value in seconds\n";
	}
}

# flesh out common IMAP-specific data structures
sub imap_common_init ($) {
	my ($self) = @_;
	my $cfg = $self->{config};
	my $mic_args = {}; # scheme://authority => Mail:IMAPClient arg
	for my $url (sort keys %{$self->{imap}}) {
		my $uri = PublicInbox::URIimap->new($url);
		my $sec = imap_section($uri);
		for my $f (qw(Starttls Debug Compress)) {
			my $k = "imap.$f";
			my $orig = $cfg->urlmatch($k, $url) // next;
			my $v = PublicInbox::Config::_git_config_bool($orig);
			if (defined($v)) {
				$mic_args->{$sec}->{$f} = $v;
			} else {
				warn "W: $k=$orig for $url is not boolean\n";
			}
		}
		my $to = cfg_intvl($cfg, 'imap.timeout', $url);
		$mic_args->{$sec}->{Timeout} = $to if $to;
		$to = cfg_intvl($cfg, 'imap.pollInterval', $url);
		$self->{imap_opt}->{$sec}->{poll_intvl} = $to if $to;
		$to = cfg_intvl($cfg, 'imap.IdleInterval', $url);
		$self->{imap_opt}->{$sec}->{idle_intvl} = $to if $to;

		my $k = 'imap.fetchBatchSize';
		my $bs = $cfg->urlmatch($k, $url) // next;
		if ($bs =~ /\A([0-9]+)\z/) {
			$self->{imap_opt}->{$sec}->{batch_size} = $bs;
		} else {
			warn "$k=$bs is not an integer\n";
		}
	}
	$mic_args;
}

sub auth_anon_cb { '' }; # for Mail::IMAPClient::Authcallback

sub mic_for ($$$) { # mic = Mail::IMAPClient
	my ($self, $uri, $mic_args) = @_;
	my $url = $uri->as_string;
	my $cred = {
		url => $url,
		protocol => $uri->scheme,
		host => $uri->host,
		username => $uri->user,
		password => $uri->password,
	};
	my $common = $mic_args->{imap_section($uri)} // {};
	my $host = $cred->{host};
	my $mic_arg = {
		Port => $uri->port,
		# IMAPClient mishandles `0', so we pass `127.0.0.1'
		Server => $host eq '0' ? '127.0.0.1' : $host,
		Ssl => $uri->scheme eq 'imaps',
		Keepalive => 1, # SO_KEEPALIVE
		%$common, # may set Starttls, Compress, Debug ....
	};
	my $mic = PublicInbox::IMAPClient->new(%$mic_arg) or
		die "E: <$url> new: $@\n";

	# default to using STARTTLS if it's available, but allow
	# it to be disabled since I usually connect to localhost
	if (!$mic_arg->{Ssl} && !defined($mic_arg->{Starttls}) &&
			$mic->has_capability('STARTTLS') &&
			$mic->can('starttls')) {
		$mic->starttls or die "E: <$url> STARTTLS: $@\n";
	}

	# do we even need credentials?
	if (!defined($cred->{username}) &&
			$mic->has_capability('AUTH=ANONYMOUS')) {
		$cred = undef;
	}
	if ($cred) {
		Git::credential($cred, 'fill'); # may prompt user here
		$mic->User($mic_arg->{User} = $cred->{username});
		$mic->Password($mic_arg->{Password} = $cred->{password});
	} else { # AUTH=ANONYMOUS
		$mic->Authmechanism($mic_arg->{Authmechanism} = 'ANONYMOUS');
		$mic->Authcallback($mic_arg->{Authcallback} = \&auth_anon_cb);
	}
	if ($mic->login && $mic->IsAuthenticated) {
		# success! keep IMAPClient->new arg in case we get disconnected
		$self->{mic_arg}->{imap_section($uri)} = $mic_arg;
	} else {
		warn "E: <$url> LOGIN: $@\n";
		$mic = undef;
	}
	Git::credential($cred, $mic ? 'approve' : 'reject') if $cred;
	$mic;
}

sub imap_import_msg ($$$$) {
	my ($self, $url, $uid, $raw) = @_;
	# our target audience expects LF-only, save storage
	$$raw =~ s/\r\n/\n/sg;

	my $inboxes = $self->{imap}->{$url};
	if (ref($inboxes)) {
		for my $ibx (@$inboxes) {
			my $eml = PublicInbox::Eml->new($$raw);
			my $x = import_eml($self, $ibx, $eml);
		}
	} elsif ($inboxes eq 'watchspam') {
		my $eml = PublicInbox::Eml->new($raw);
		my $arg = [ $self, $eml, "$url UID:$uid" ];
		$self->{config}->each_inbox(\&remove_eml_i, $arg);
	} else {
		die "BUG: destination unknown $inboxes";
	}
}

sub imap_fetch_all ($$$) {
	my ($self, $mic, $uri) = @_;
	my $sec = imap_section($uri);
	my $mbx = $uri->mailbox;
	my $url = $uri->as_string;
	$mic->Clear(1); # trim results history
	$mic->examine($mbx) or return "E: EXAMINE $mbx ($sec) failed: $!";
	my ($r_uidval, $r_uidnext);
	for ($mic->Results) {
		/^\* OK \[UIDVALIDITY ([0-9]+)\].*/ and $r_uidval = $1;
		/^\* OK \[UIDNEXT ([0-9]+)\].*/ and $r_uidnext = $1;
		last if $r_uidval && $r_uidnext;
	}
	$r_uidval //= $mic->uidvalidity($mbx) //
		return "E: $url cannot get UIDVALIDITY";
	$r_uidnext //= $mic->uidnext($mbx) //
		return "E: $url cannot get UIDNEXT";
	my $itrk = PublicInbox::IMAPTracker->new($url);
	my ($l_uidval, $l_uid) = $itrk->get_last;
	$l_uidval //= $r_uidval; # first time
	$l_uid //= 1;
	if ($l_uidval != $r_uidval) {
		return "E: $url UIDVALIDITY mismatch\n".
			"E: local=$l_uidval != remote=$r_uidval";
	}
	my $r_uid = $r_uidnext - 1;
	if ($l_uid != 1 && $l_uid > $r_uid) {
		return "E: $url local UID exceeds remote ($l_uid > $r_uid)\n".
			"E: $url strangely, UIDVALIDLITY matches ($l_uidval)\n";
	}
	return if $l_uid >= $r_uid; # nothing to do

	warn "I: $url fetching UID $l_uid:$r_uid\n";
	$mic->Uid(1); # the default, we hope
	my $bs = $self->{imap_opt}->{$sec}->{batch_size} // 1;
	my $req = $mic->imap4rev1 ? 'BODY.PEEK[]' : 'RFC822.PEEK';

	# TODO: FLAGS may be useful for personal use
	my $key = $req;
	$key =~ s/\.PEEK//;
	my ($uids, $batch);
	my $warn_cb = $SIG{__WARN__} || sub { print STDERR @_ };
	local $SIG{__WARN__} = sub {
		$batch //= '?';
		$warn_cb->("$url UID:$batch\n");
		$warn_cb->(@_);
	};
	my $err;
	do {
		# I wish "UID FETCH $START:*" could work, but:
		# 1) servers do not need to return results in any order
		# 2) Mail::IMAPClient doesn't offer a streaming API
		$uids = $mic->search("UID $l_uid:*") or
			return "E: $url UID SEARCH $l_uid:* error: $!";
		return if scalar(@$uids) == 0;

		# RFC 3501 doesn't seem to indicate order of UID SEARCH
		# responses, so sort it ourselves.  Order matters so
		# IMAPTracker can store the newest UID.
		@$uids = sort { $a <=> $b } @$uids;

		# Did we actually get new messages?
		return if $uids->[0] < $l_uid;

		$l_uid = $uids->[-1] + 1; # for next search
		my $last_uid;

		while (scalar @$uids) {
			my @batch = splice(@$uids, 0, $bs);
			$batch = join(',', @batch);
			local $0 = "UID:$batch $mbx $sec";
			my $r = $mic->fetch_hash($batch, $req);
			unless ($r) { # network error?
				$err = "E: $url UID FETCH $batch error: $!";
				last;
			}
			for my $uid (@batch) {
				# messages get deleted, so holes appear
				my $per_uid = delete $r->{$uid} // next;
				my $raw = delete($per_uid->{$key}) // next;
				imap_import_msg($self, $url, $uid, \$raw);
				$last_uid = $uid;
				last if $self->{quit};
			}
			last if $self->{quit};
		}
		_done_for_now($self);
		$itrk->update_last($r_uidval, $last_uid) if defined $last_uid;
	} until ($err || $self->{quit});
	$err;
}

sub imap_idle_once ($$$$) {
	my ($self, $mic, $intvl, $url) = @_;
	my $i = $intvl //= (29 * 60);
	my $end = now() + $intvl;
	warn "I: $url idling for ${intvl}s\n";
	local $0 = "IDLE $0";
	unless ($mic->idle) {
		return if $self->{quit};
		return "E: IDLE failed on $url: $!";
	}
	$self->{idle_mic} = $mic; # for ->quit
	my @res;
	until ($self->{quit} || grep(/^\* [0-9]+ EXISTS/, @res) || $i <= 0) {
		@res = $mic->idle_data($i);
		$i = $end - now();
	}
	delete $self->{idle_mic};
	unless ($self->{quit}) {
		$mic->IsConnected or return "E: IDLE disconnected on $url";
		$mic->done or return "E: IDLE DONE failed on $url: $!";
	}
	undef;
}

# idles on a single URI
sub watch_imap_idle_1 ($$$) {
	my ($self, $uri, $intvl) = @_;
	my $sec = imap_section($uri);
	my $mic_arg = $self->{mic_arg}->{$sec} or
			die "BUG: no Mail::IMAPClient->new arg for $sec";
	my $mic;
	local $0 = $uri->mailbox." $sec";
	until ($self->{quit}) {
		$mic //= delete($self->{mics}->{$sec}) //
				PublicInbox::IMAPClient->new(%$mic_arg);
		my $err = imap_fetch_all($self, $mic, $uri);
		$err //= imap_idle_once($self, $mic, $intvl, $uri->as_string);
		if ($err && !$self->{quit}) {
			warn $err, "\n";
			$mic = undef;
			sleep 60 unless $self->{quit};
		}
	}
}

sub watch_atfork_child ($) {
	my ($self) = @_;
	delete $self->{idle_pids};
	delete $self->{poll_pids};
	delete $self->{opendirs};
	PublicInbox::DS->Reset;
	PublicInbox::Sigfd::sig_setmask($self->{oldset});
	%SIG = (%SIG, %{$self->{sig}});
}

sub watch_atfork_parent ($) {
	my ($self) = @_;
	_done_for_now($self);
	$self->{mics} = {}; # going to be forking, so disconnect
}

sub imap_idle_reap { # PublicInbox::DS::dwaitpid callback
	my ($self, $pid) = @_;
	my $uri_intvl = delete $self->{idle_pids}->{$pid} or
		die "BUG: PID=$pid (unknown) reaped: \$?=$?\n";

	my ($uri, $intvl) = @$uri_intvl;
	my $url = $uri->as_string;
	return if $self->{quit};
	warn "W: PID=$pid on $url died: \$?=$?\n" if $?;
	push @{$self->{idle_todo}}, $uri_intvl;
	PubicInbox::DS::requeue($self); # call ->event_step to respawn
}

sub imap_idle_fork ($$) {
	my ($self, $uri_intvl) = @_;
	my ($uri, $intvl) = @$uri_intvl;
	defined(my $pid = fork) or die "fork: $!";
	if ($pid == 0) {
		watch_atfork_child($self);
		watch_imap_idle_1($self, $uri, $intvl);
		_exit(0);
	}
	$self->{idle_pids}->{$pid} = $uri_intvl;
	PublicInbox::DS::dwaitpid($pid, \&imap_idle_reap, $self);
}

sub event_step {
	my ($self) = @_;
	return if $self->{quit};
	my $idle_todo = $self->{idle_todo};
	if ($idle_todo && @$idle_todo) {
		watch_atfork_parent($self);
		while (my $uri_intvl = shift(@$idle_todo)) {
			imap_idle_fork($self, $uri_intvl);
		}
	}
	goto(&fs_scan_step) if $self->{mdre};
}

sub watch_imap_fetch_all ($$) {
	my ($self, $uris) = @_;
	for my $uri (@$uris) {
		my $sec = imap_section($uri);
		my $mic_arg = $self->{mic_arg}->{$sec} or
			die "BUG: no Mail::IMAPClient->new arg for $sec";
		my $mic = PublicInbox::IMAPClient->new(%$mic_arg) or next;
		my $err = imap_fetch_all($self, $mic, $uri);
		last if $self->{quit};
		warn $err, "\n" if $err;
	}
}

sub imap_fetch_fork ($) { # DS::add_timer callback
	my ($self, $intvl, $uris) = @{$_[0]};
	return if $self->{quit};
	watch_atfork_parent($self);
	defined(my $pid = fork) or die "fork: $!";
	if ($pid == 0) {
		watch_atfork_child($self);
		watch_imap_fetch_all($self, $uris);
		_exit(0);
	}
	$self->{poll_pids}->{$pid} = [ $intvl, $uris ];
	PublicInbox::DS::dwaitpid($pid, \&imap_fetch_reap, $self);
}

sub imap_fetch_reap { # PublicInbox::DS::dwaitpid callback
	my ($self, $pid) = @_;
	my $intvl_uris = delete $self->{poll_pids}->{$pid} or
		die "BUG: PID=$pid (unknown) reaped: \$?=$?\n";
	return if $self->{quit};
	my ($intvl, $uris) = @$intvl_uris;
	if ($?) {
		warn "W: PID=$pid died: \$?=$?\n",
			map { $_->as_string."\n" } @$uris;
	}
	warn('I: will check ', $_->as_string, " in ${intvl}s\n") for @$uris;
	PublicInbox::DS::add_timer($intvl, \&imap_fetch_fork,
					[$self, $intvl, $uris]);
}

sub watch_imap_init ($) {
	my ($self) = @_;
	eval { require PublicInbox::IMAPClient } or
		die "Mail::IMAPClient is required for IMAP:\n$@\n";
	eval { require Git } or
		die "Git (Perl module) is required for IMAP:\n$@\n";
	eval { require PublicInbox::IMAPTracker } or
		die "DBD::SQLite is required for IMAP\n:$@\n";

	my $mic_args = imap_common_init($self); # read args from config

	# make sure we can connect and cache the credentials in memory
	$self->{mic_arg} = {}; # schema://authority => IMAPClient->new args
	my $mics = $self->{mics} = {}; # schema://authority => IMAPClient obj
	for my $url (sort keys %{$self->{imap}}) {
		my $uri = PublicInbox::URIimap->new($url);
		$mics->{imap_section($uri)} //= mic_for($self, $uri, $mic_args);
	}

	my $idle = []; # [ [ uri1, intvl1 ], [uri2, intvl2] ]
	my $poll = {}; # intvl_seconds => [ uri1, uri2 ]
	for my $url (keys %{$self->{imap}}) {
		my $uri = PublicInbox::URIimap->new($url);
		my $sec = imap_section($uri);
		my $mic = $mics->{$sec};
		my $intvl = $self->{imap_opt}->{$sec}->{poll_intvl};
		if ($mic->has_capability('IDLE') && !$intvl) {
			$intvl = $self->{imap_opt}->{$sec}->{idle_intvl};
			push @$idle, [ $uri, $intvl // () ];
		} else {
			push @{$poll->{$intvl || 120}}, $uri;
		}
	}
	if (scalar @$idle) {
		$self->{idle_pids} = {};
		$self->{idle_todo} = $idle;
		PublicInbox::DS::requeue($self); # ->event_step to fork
	}
	return unless scalar keys %$poll;
	$self->{poll_pids} = {};

	# poll all URIs for a given interval sequentially
	while (my ($intvl, $uris) = each %$poll) {
		PublicInbox::DS::add_timer(0, \&imap_fetch_fork,
						[$self, $intvl, $uris]);
	}
}

sub watch {
	my ($self, $sig, $oldset) = @_;
	$self->{oldset} = $oldset;
	$self->{sig} = $sig;
	watch_imap_init($self) if $self->{imap};
	watch_fs_init($self) if $self->{mdre};
	PublicInbox::DS->SetPostLoopCallback(sub {});
	PublicInbox::DS->EventLoop until $self->{quit};
	_done_for_now($self);
}

sub trigger_scan {
	my ($self, $op) = @_;
	push @{$self->{ops}}, $op;
	PublicInbox::DS::requeue($self);
}

sub fs_scan_step {
	my ($self) = @_;
	return if $self->{quit};
	my $op = shift @{$self->{ops}};

	# continue existing scan
	my $max = 10;
	my $opendirs = $self->{opendirs};
	my @dirnames = keys %$opendirs;
	foreach my $dir (@dirnames) {
		my $dh = delete $opendirs->{$dir};
		my $n = $max;
		while (my $fn = readdir($dh)) {
			_try_path($self, "$dir/$fn");
			last if --$n < 0;
		}
		$opendirs->{$dir} = $dh if $n < 0;
	}
	if ($op && $op eq 'full') {
		foreach my $dir (keys %{$self->{mdmap}}) {
			next if $opendirs->{$dir}; # already in progress
			my $ok = opendir(my $dh, $dir);
			unless ($ok) {
				warn "failed to open $dir: $!\n";
				next;
			}
			my $n = $max;
			while (my $fn = readdir($dh)) {
				_try_path($self, "$dir/$fn");
				last if --$n < 0;
			}
			$opendirs->{$dir} = $dh if $n < 0;
		}
	}
	_done_for_now($self);
	# do we have more work to do?
	PublicInbox::DS::requeue($self) if keys %$opendirs;
}

sub scan {
	my ($self, $op) = @_;
	push @{$self->{ops}}, $op;
	goto &fs_scan_step;
}

sub _importer_for {
	my ($self, $ibx) = @_;
	my $importers = $self->{importers};
	my $im = $importers->{"$ibx"} ||= $ibx->importer(0);
	if (scalar(keys(%$importers)) > 2) {
		delete $importers->{"$ibx"};
		_done_for_now($self);
	}

	$importers->{"$ibx"} = $im;
}

sub _spamcheck_cb {
	my ($sc) = @_;
	sub {
		my ($mime) = @_;
		my $tmp = '';
		if ($sc->spamcheck($mime, \$tmp)) {
			return PublicInbox::Eml->new(\$tmp);
		}
		warn $mime->header('Message-ID')." failed spam check\n";
		undef;
	}
}

sub is_maildir {
	$_[0] =~ s!\Amaildir:!! or return;
	$_[0] =~ tr!/!/!s;
	$_[0] =~ s!/\z!!;
	$_[0];
}

sub is_watchspam {
	my ($cur, $ws, $ibx) = @_;
	if ($ws && !ref($ws) && $ws eq 'watchspam') {
		warn <<EOF;
E: $cur is a spam folder and cannot be used for `$ibx->{name}' input
EOF
		return 1;
	}
	undef;
}

sub imap_url {
	my ($url) = @_;
	require PublicInbox::URIimap;
	my $uri = PublicInbox::URIimap->new($url);
	$uri ? $uri->canonical->as_string : undef;
}

1;
