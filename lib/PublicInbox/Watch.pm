# Copyright (C) 2016-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# ref: https://cr.yp.to/proto/maildir.html
#	httsp://wiki2.dovecot.org/MailboxFormat/Maildir
package PublicInbox::Watch;
use strict;
use v5.10.1;
use PublicInbox::Eml;
use PublicInbox::InboxWritable qw(eml_from_path);
use PublicInbox::MdirReader;
use PublicInbox::NetReader;
use PublicInbox::Filter::Base qw(REJECT);
use PublicInbox::Spamcheck;
use PublicInbox::Sigfd;
use PublicInbox::DS qw(now add_timer);
use PublicInbox::MID qw(mids);
use PublicInbox::ContentHash qw(content_hash);
use PublicInbox::EOFpipe;
use POSIX qw(_exit WNOHANG);

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
	my ($class, $cfg) = @_;
	my (%mdmap, $spamc);
	my (%imap, %nntp); # url => [inbox objects] or 'watchspam'

	# "publicinboxwatch" is the documented namespace
	# "publicinboxlearn" is legacy but may be supported
	# indefinitely...
	foreach my $pfx (qw(publicinboxwatch publicinboxlearn)) {
		my $k = "$pfx.watchspam";
		defined(my $dirs = $cfg->{$k}) or next;
		$dirs = PublicInbox::Config::_array($dirs);
		for my $dir (@$dirs) {
			my $url;
			if (is_maildir($dir)) {
				# skip "new", no MUA has seen it, yet.
				$mdmap{"$dir/cur"} = 'watchspam';
			} elsif ($url = imap_url($dir)) {
				$imap{$url} = 'watchspam';
			} elsif ($url = nntp_url($dir)) {
				$nntp{$url} = 'watchspam';
			} else {
				warn "unsupported $k=$dir\n";
			}
		}
	}

	my $k = 'publicinboxwatch.spamcheck';
	my $default = undef;
	my $spamcheck = PublicInbox::Spamcheck::get($cfg, $k, $default);
	$spamcheck = _spamcheck_cb($spamcheck) if $spamcheck;

	$cfg->each_inbox(sub {
		# need to make all inboxes writable for spam removal:
		my $ibx = $_[0] = PublicInbox::InboxWritable->new($_[0]);

		my $watches = $ibx->{watch} or return;
		$watches = PublicInbox::Config::_array($watches);
		for my $watch (@$watches) {
			my $url;
			if (is_maildir($watch)) {
				compile_watchheaders($ibx);
				my ($new, $cur) = ("$watch/new", "$watch/cur");
				my $cur_dst = $mdmap{$cur} //= [];
				return if is_watchspam($cur, $cur_dst, $ibx);
				push @{$mdmap{$new} //= []}, $ibx;
				push @$cur_dst, $ibx;
			} elsif ($url = imap_url($watch)) {
				return if is_watchspam($url, $imap{$url}, $ibx);
				compile_watchheaders($ibx);
				push @{$imap{$url} ||= []}, $ibx;
			} elsif ($url = nntp_url($watch)) {
				return if is_watchspam($url, $nntp{$url}, $ibx);
				compile_watchheaders($ibx);
				push @{$nntp{$url} ||= []}, $ibx;
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
	return unless $mdre || scalar(keys %imap) || scalar(keys %nntp);

	bless {
		max_batch => 10, # avoid hogging locks for too long
		spamcheck => $spamcheck,
		mdmap => \%mdmap,
		mdre => $mdre,
		pi_cfg => $cfg,
		imap => scalar keys %imap ? \%imap : undef,
		nntp => scalar keys %nntp? \%nntp : undef,
		importers => {},
		opendirs => {}, # dirname => dirhandle (in progress scans)
		ops => [], # 'quit', 'full'
	}, $class;
}

sub _done_for_now {
	my ($self) = @_;
	local $PublicInbox::DS::in_loop = 0; # waitpid() synchronously
	for my $im (values %{$self->{importers}}) {
		next if !$im; # $im may be undef during cleanup
		eval { $im->done };
		warn "$im->{ibx}->{name} ->done: $@\n" if $@;
	}
}

sub remove_eml_i { # each_inbox callback
	my ($ibx, $self, $eml, $loc) = @_;

	eval {
		# try to avoid taking a lock or unnecessary spawning
		my $im = $self->{importers}->{"$ibx"};
		my $scrubbed;
		if ((!$im || !$im->active) && $ibx->over) {
			if (content_exists($ibx, $eml)) {
				# continue
			} elsif (my $scrub = $ibx->filter($im)) {
				$scrubbed = $scrub->scrub($eml, 1);
				if ($scrubbed && $scrubbed != REJECT &&
					  !content_exists($ibx, $scrubbed)) {
					return;
				}
			} else {
				return;
			}
		}

		$im //= _importer_for($self, $ibx); # may spawn fast-import
		$im->remove($eml, 'spam');
		$scrubbed //= do {
			my $scrub = $ibx->filter($im);
			$scrub ? $scrub->scrub($eml, 1) : undef;
		};
		if ($scrubbed && $scrubbed != REJECT) {
			$im->remove($scrubbed, 'spam');
		}
	};
	if ($@) {
		warn "error removing spam at: $loc from $ibx->{name}: $@\n";
		_done_for_now($self);
	}
}

sub _remove_spam {
	my ($self, $path) = @_;
	# path must be marked as (S)een
	$path =~ /:2,[A-R]*S[T-Za-z]*\z/ or return;
	my $eml = eml_from_path($path) or return;
	local $SIG{__WARN__} = PublicInbox::Eml::warn_ignore_cb();
	$self->{pi_cfg}->each_inbox(\&remove_eml_i, $self, $eml, $path);
}

sub import_eml ($$$) {
	my ($self, $ibx, $eml) = @_;

	# any header match means it's eligible for the inbox:
	if (my $watch_hdrs = $ibx->{-watchheaders}) {
		my $ok;
		for my $wh (@$watch_hdrs) {
			my @v = $eml->header_raw($wh->[0]);
			$ok = grep(/$wh->[1]/, @v) and last;
		}
		return unless $ok;
	}
	eval {
		my $im = _importer_for($self, $ibx);
		if (my $scrub = $ibx->filter($im)) {
			my $scrubbed = $scrub->scrub($eml) or return;
			$scrubbed == REJECT and return;
			$eml = $scrubbed;
		}
		$im->add($eml, $self->{spamcheck});
	};
	if ($@) {
		warn "$ibx->{name} add failed: $@\n";
		_done_for_now($self);
	}
}

sub _try_path {
	my ($self, $path) = @_;
	my $fl = PublicInbox::MdirReader::maildir_path_flags($path) // return;
	return if $fl =~ /[DT]/; # no Drafts or Trash
	if ($path !~ $self->{mdre}) {
		warn "unrecognized path: $path\n";
		return;
	}
	my $inboxes = $self->{mdmap}->{$1};
	unless ($inboxes) {
		warn "unmappable dir: $1\n";
		return;
	}
	my $warn_cb = $SIG{__WARN__} || \&CORE::warn;
	local $SIG{__WARN__} = sub {
		my $pfx = ($_[0] // '') =~ /^([A-Z]: )/g ? $1 : '';
		$warn_cb->($pfx, "path: $path\n", @_);
	};
	if (!ref($inboxes) && $inboxes eq 'watchspam') {
		return _remove_spam($self, $path);
	}
	foreach my $ibx (@$inboxes) {
		my $eml = eml_from_path($path) or next;
		import_eml($self, $ibx, $eml);
	}
}

sub quit_done ($) {
	my ($self) = @_;
	return unless $self->{quit};

	# don't have reliable wakeups, keep signalling
	my $done = 1;
	for (qw(idle_pids poll_pids)) {
		my $pids = $self->{$_} or next;
		for (keys %$pids) {
			$done = undef if kill('QUIT', $_);
		}
	}
	$done;
}

sub quit {
	my ($self) = @_;
	$self->{quit} = 1;
	%{$self->{opendirs}} = ();
	_done_for_now($self);
	quit_done($self);
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
	my $cb = sub { # called by PublicInbox::DirIdle::event_step
		_try_path($self, $_[0]->fullname);
		$self->{done_timer} //= PublicInbox::DS::requeue($done);
	};
	require PublicInbox::DirIdle;
	# inotify_create + EPOLL_CTL_ADD
	PublicInbox::DirIdle->new([keys %{$self->{mdmap}}], $cb);
}

sub imap_import_msg ($$$$$) {
	my ($self, $url, $uid, $raw, $flags) = @_;
	# our target audience expects LF-only, save storage
	$$raw =~ s/\r\n/\n/sg;

	my $inboxes = $self->{imap}->{$url};
	if (ref($inboxes)) {
		for my $ibx (@$inboxes) {
			my $eml = PublicInbox::Eml->new($$raw);
			import_eml($self, $ibx, $eml);
		}
	} elsif ($inboxes eq 'watchspam') {
		return if $flags !~ /\\Seen\b/; # don't remove unseen messages
		local $SIG{__WARN__} = PublicInbox::Eml::warn_ignore_cb();
		my $eml = PublicInbox::Eml->new($raw);
		$self->{pi_cfg}->each_inbox(\&remove_eml_i,
						$self, $eml, "$url UID:$uid");
	} else {
		die "BUG: destination unknown $inboxes";
	}
}

sub imap_fetch_all ($$$) {
	my ($self, $mic, $url) = @_;
	my $uri = PublicInbox::URIimap->new($url);
	my $sec = uri_section($uri);
	my $mbx = $uri->mailbox;
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
	my $warn_cb = $SIG{__WARN__} || \&CORE::warn;
	local $SIG{__WARN__} = sub {
		my $pfx = ($_[0] // '') =~ /^([A-Z]: )/g ? $1 : '';
		$batch //= '?';
		$warn_cb->("$pfx$url UID:$batch\n", @_);
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
		my $n = $self->{max_batch};

		while (scalar @$uids) {
			if (--$n < 0) {
				_done_for_now($self);
				$itrk->update_last($r_uidval, $last_uid);
				$n = $self->{max_batch};
			}
			my @batch = splice(@$uids, 0, $bs);
			$batch = join(',', @batch);
			local $0 = "UID:$batch $mbx $sec";
			my $r = $mic->fetch_hash($batch, $req, 'FLAGS');
			unless ($r) { # network error?
				$err = "E: $url UID FETCH $batch error: $!";
				last;
			}
			for my $uid (@batch) {
				# messages get deleted, so holes appear
				my $per_uid = delete $r->{$uid} // next;
				my $raw = delete($per_uid->{$key}) // next;
				my $fl = $per_uid->{FLAGS} // '';
				imap_import_msg($self, $url, $uid, \$raw, $fl);
				$last_uid = $uid;
				last if $self->{quit};
			}
			last if $self->{quit};
		}
		_done_for_now($self);
		$itrk->update_last($r_uidval, $last_uid);
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
	until ($self->{quit} || !$mic->IsConnected ||
			grep(/^\* [0-9]+ EXISTS/, @res) || $i <= 0) {
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
	my ($self, $url, $intvl) = @_;
	my $uri = PublicInbox::URIimap->new($url);
	my $sec = uri_section($uri);
	my $mic_arg = $self->{mic_arg}->{$sec} or
			die "BUG: no Mail::IMAPClient->new arg for $sec";
	my $mic;
	local $0 = $uri->mailbox." $sec";
	until ($self->{quit}) {
		$mic //= PublicInbox::IMAPClient->new(%$mic_arg);
		my $err;
		if ($mic && $mic->IsConnected) {
			$err = imap_fetch_all($self, $mic, $url);
			$err //= imap_idle_once($self, $mic, $intvl, $url);
		} else {
			$err = "E: not connected: $!";
		}
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
	%SIG = (%SIG, %{$self->{sig}}, CHLD => 'DEFAULT');
	PublicInbox::DS::sig_setmask($self->{oldset});
}

sub watch_atfork_parent ($) {
	my ($self) = @_;
	_done_for_now($self);
	PublicInbox::DS::block_signals();
}

sub imap_idle_requeue { # DS::add_timer callback
	my ($self, $url_intvl) = @_;
	return if $self->{quit};
	push @{$self->{idle_todo}}, $url_intvl;
	event_step($self);
}

sub imap_idle_reap { # PublicInbox::DS::dwaitpid callback
	my ($self, $pid) = @_;
	my $url_intvl = delete $self->{idle_pids}->{$pid} or
		die "BUG: PID=$pid (unknown) reaped: \$?=$?\n";

	my ($url, $intvl) = @$url_intvl;
	return if $self->{quit};
	warn "W: PID=$pid on $url died: \$?=$?\n" if $?;
	add_timer(60, \&imap_idle_requeue, $self, $url_intvl);
}

sub reap { # callback for EOFpipe
	my ($pid, $cb, $self) = @{$_[0]};
	my $ret = waitpid($pid, 0);
	if ($ret == $pid) {
		$cb->($self, $pid); # poll_fetch_reap || imap_idle_reap
	} else {
		warn "W: waitpid($pid) => ", $ret // "($!)", "\n";
	}
}

sub imap_idle_fork ($$) {
	my ($self, $url_intvl) = @_;
	my ($url, $intvl) = @$url_intvl;
	pipe(my ($r, $w)) or die "pipe: $!";
	my $seed = rand(0xffffffff);
	my $pid = fork // die "fork: $!";
	if ($pid == 0) {
		srand($seed);
		eval { Net::SSLeay::randomize() };
		close $r;
		watch_atfork_child($self);
		watch_imap_idle_1($self, $url, $intvl);
		close $w;
		_exit(0);
	}
	$self->{idle_pids}->{$pid} = $url_intvl;
	PublicInbox::EOFpipe->new($r, \&reap, [$pid, \&imap_idle_reap, $self]);
}

sub event_step {
	my ($self) = @_;
	return if $self->{quit};
	my $idle_todo = $self->{idle_todo};
	if ($idle_todo && @$idle_todo) {
		my $oldset = watch_atfork_parent($self);
		eval {
			while (my $url_intvl = shift(@$idle_todo)) {
				imap_idle_fork($self, $url_intvl);
			}
		};
		PublicInbox::DS::sig_setmask($oldset);
		die $@ if $@;
	}
	fs_scan_step($self) if $self->{mdre};
}

sub watch_imap_fetch_all ($$) {
	my ($self, $urls) = @_;
	for my $url (@$urls) {
		my $uri = PublicInbox::URIimap->new($url);
		my $sec = uri_section($uri);
		my $mic_arg = $self->{mic_arg}->{$sec} or
			die "BUG: no Mail::IMAPClient->new arg for $sec";
		my $mic = PublicInbox::IMAPClient->new(%$mic_arg) or next;
		my $err = imap_fetch_all($self, $mic, $url);
		last if $self->{quit};
		warn $err, "\n" if $err;
	}
}

sub watch_nntp_fetch_all ($$) {
	my ($self, $urls) = @_;
	for my $url (@$urls) {
		my $uri = uri_new($url);
		my $sec = uri_section($uri);
		my $nn_arg = $self->{nn_arg}->{$sec} or
			die "BUG: no Net::NNTP->new arg for $sec";
		my $nntp_opt = $self->{nntp_opt}->{$sec};
		my $nn = nn_new($nn_arg, $nntp_opt, $url);
		unless ($nn) {
			warn "E: $url: \$!=$!\n";
			next;
		}
		last if $self->{quit};
		if (my $postconn = $nntp_opt->{-postconn}) {
			for my $m_arg (@$postconn) {
				my ($method, @args) = @$m_arg;
				$nn->$method(@args) and next;
				warn "E: <$url> $method failed\n";
				$nn = undef;
				last;
			}
		}
		last if $self->{quit};
		if ($nn) {
			my $err = nntp_fetch_all($self, $nn, $url);
			warn $err, "\n" if $err;
		}
	}
}

sub poll_fetch_fork { # DS::add_timer callback
	my ($self, $intvl, $urls) = @_;
	return if $self->{quit};
	pipe(my ($r, $w)) or die "pipe: $!";
	my $oldset = watch_atfork_parent($self);
	my $seed = rand(0xffffffff);
	my $pid = fork;
	if (defined($pid) && $pid == 0) {
		srand($seed);
		eval { Net::SSLeay::randomize() };
		close $r;
		watch_atfork_child($self);
		if ($urls->[0] =~ m!\Aimaps?://!i) {
			watch_imap_fetch_all($self, $urls);
		} else {
			watch_nntp_fetch_all($self, $urls);
		}
		close $w;
		_exit(0);
	}
	PublicInbox::DS::sig_setmask($oldset);
	die "fork: $!"  unless defined $pid;
	$self->{poll_pids}->{$pid} = [ $intvl, $urls ];
	PublicInbox::EOFpipe->new($r, \&reap, [$pid, \&poll_fetch_reap, $self]);
}

sub poll_fetch_reap {
	my ($self, $pid) = @_;
	my $intvl_urls = delete $self->{poll_pids}->{$pid} or
		die "BUG: PID=$pid (unknown) reaped: \$?=$?\n";
	return if $self->{quit};
	my ($intvl, $urls) = @$intvl_urls;
	if ($?) {
		warn "W: PID=$pid died: \$?=$?\n", map { "$_\n" } @$urls;
	}
	warn("I: will check $_ in ${intvl}s\n") for @$urls;
	add_timer($intvl, \&poll_fetch_fork, $self, $intvl, $urls);
}

sub watch_imap_init ($$) {
	my ($self, $poll) = @_;
	my $mics = imap_common_init($self); # read args from config
	my $idle = []; # [ [ url1, intvl1 ], [url2, intvl2] ]
	for my $url (keys %{$self->{imap}}) {
		my $uri = PublicInbox::URIimap->new($url);
		my $sec = uri_section($uri);
		my $mic = $mics->{$sec};
		my $intvl = $self->{imap_opt}->{$sec}->{pollInterval};
		if ($mic->has_capability('IDLE') && !$intvl) {
			$intvl = $self->{imap_opt}->{$sec}->{idleInterval};
			push @$idle, [ $url, $intvl // () ];
		} else {
			push @{$poll->{$intvl || 120}}, $url;
		}
	}
	if (scalar @$idle) {
		$self->{idle_todo} = $idle;
		PublicInbox::DS::requeue($self); # ->event_step to fork
	}
}

# flesh out common NNTP-specific data structures
sub nntp_common_init ($) {
	my ($self) = @_;
	my $cfg = $self->{pi_cfg};
	my $nn_args = {}; # scheme://authority => Net::NNTP->new arg
	for my $url (sort keys %{$self->{nntp}}) {
		my $sec = uri_section(uri_new($url));

		# Debug and Timeout are passed to Net::NNTP->new
		my $v = cfg_bool($cfg, 'nntp.Debug', $url);
		$nn_args->{$sec}->{Debug} = $v if defined $v;
		my $to = cfg_intvl($cfg, 'nntp.Timeout', $url);
		$nn_args->{$sec}->{Timeout} = $to if $to;

		# Net::NNTP post-connect commands
		for my $k (qw(starttls compress)) {
			$v = cfg_bool($cfg, "nntp.$k", $url) // next;
			$self->{nntp_opt}->{$sec}->{$k} = $v;
		}

		# internal option
		for my $k (qw(pollInterval)) {
			$to = cfg_intvl($cfg, "nntp.$k", $url) // next;
			$self->{nntp_opt}->{$sec}->{$k} = $to;
		}
	}
	$nn_args;
}

sub nntp_fetch_all ($$$) {
	my ($self, $nn, $url) = @_;
	my $uri = uri_new($url);
	my ($group, $num_a, $num_b) = $uri->group;
	my $sec = uri_section($uri);
	my ($nr, $beg, $end) = $nn->group($group);
	unless (defined($nr)) {
		chomp(my $msg = $nn->message);
		return "E: GROUP $group <$sec> $msg";
	}

	# IMAPTracker is also used for tracking NNTP, UID == article number
	# LIST.ACTIVE can get the equivalent of UIDVALIDITY, but that's
	# expensive.  So we assume newsgroups don't change:
	my $itrk = PublicInbox::IMAPTracker->new($url);
	my (undef, $l_art) = $itrk->get_last;
	$l_art //= $beg; # initial import

	# allow users to specify articles to refetch
	# cf. https://tools.ietf.org/id/draft-gilman-news-url-01.txt
	# nntp://example.com/inbox.foo/$num_a-$num_b
	$l_art = $num_a if defined($num_a) && $num_a < $l_art;
	$end = $num_b if defined($num_b) && $num_b < $end;

	return if $l_art >= $end; # nothing to do
	$beg = $l_art + 1;

	warn "I: $url fetching ARTICLE $beg..$end\n";
	my $warn_cb = $SIG{__WARN__} || \&CORE::warn;
	my ($err, $art);
	local $SIG{__WARN__} = sub {
		my $pfx = ($_[0] // '') =~ /^([A-Z]: )/g ? $1 : '';
		$warn_cb->("$pfx$url ", $art ? ("ARTICLE $art") : (), "\n", @_);
	};
	my $inboxes = $self->{nntp}->{$url};
	my $last_art;
	my $n = $self->{max_batch};
	for ($beg..$end) {
		last if $self->{quit};
		$art = $_;
		if (--$n < 0) {
			_done_for_now($self);
			$itrk->update_last(0, $last_art);
			$n = $self->{max_batch};
		}
		my $raw = $nn->article($art);
		unless (defined($raw)) {
			my $msg = $nn->message;
			if ($nn->code == 421) { # pseudo response from Net::Cmd
				$err = "E: $msg";
				last;
			} else { # probably just a deleted message (spam)
				warn "W: $msg";
				next;
			}
		}
		s/\r\n/\n/ for @$raw;
		$raw = join('', @$raw);
		if (ref($inboxes)) {
			for my $ibx (@$inboxes) {
				my $eml = PublicInbox::Eml->new($raw);
				import_eml($self, $ibx, $eml);
			}
		} elsif ($inboxes eq 'watchspam') {
			my $eml = PublicInbox::Eml->new(\$raw);
			$self->{pi_cfg}->each_inbox(\&remove_eml_i,
					$self, $eml, "$url ARTICLE $art");
		} else {
			die "BUG: destination unknown $inboxes";
		}
		$last_art = $art;
	}
	_done_for_now($self);
	$itrk->update_last(0, $last_art);
	$err;
}

sub watch_nntp_init ($$) {
	my ($self, $poll) = @_;
	eval { require Net::NNTP } or
		die "Net::NNTP is required for NNTP:\n$@\n";
	eval { require PublicInbox::IMAPTracker } or
		die "DBD::SQLite is required for NNTP\n:$@\n";

	my $nn_args = nntp_common_init($self); # read args from config

	# make sure we can connect and cache the credentials in memory
	$self->{nn_arg} = {}; # schema://authority => Net::NNTP->new args
	for my $url (sort keys %{$self->{nntp}}) {
		nn_for($self, $url, $nn_args);
	}
	for my $url (keys %{$self->{nntp}}) {
		my $uri = uri_new($url);
		my $sec = uri_section($uri);
		my $intvl = $self->{nntp_opt}->{$sec}->{pollInterval};
		push @{$poll->{$intvl || 120}}, $url;
	}
}

sub watch { # main entry point
	my ($self, $sig, $oldset) = @_;
	$self->{oldset} = $oldset;
	$self->{sig} = $sig;
	my $poll = {}; # intvl_seconds => [ url1, url2 ]
	watch_imap_init($self, $poll) if $self->{imap};
	watch_nntp_init($self, $poll) if $self->{nntp};
	while (my ($intvl, $urls) = each %$poll) {
		# poll all URLs for a given interval sequentially
		add_timer(0, \&poll_fetch_fork, $self, $intvl, $urls);
	}
	watch_fs_init($self) if $self->{mdre};
	PublicInbox::DS->SetPostLoopCallback(sub { !$self->quit_done });
	PublicInbox::DS->EventLoop; # calls ->event_step
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
	local $PublicInbox::DS::in_loop = 0; # waitpid() synchronously

	# continue existing scan
	my $opendirs = $self->{opendirs};
	my @dirnames = keys %$opendirs;
	foreach my $dir (@dirnames) {
		my $dh = delete $opendirs->{$dir};
		my $n = $self->{max_batch};
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
			my $n = $self->{max_batch};
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
	fs_scan_step($self);
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

# XXX consider sharing with V2Writable, this only requires read-only access
sub content_exists ($$) {
	my ($ibx, $eml) = @_;
	my $over = $ibx->over or return;
	my $mids = mids($eml);
	my $chash = content_hash($eml);
	my ($id, $prev);
	for my $mid (@$mids) {
		while (my $smsg = $over->next_by_mid($mid, \$id, \$prev)) {
			my $cmp = $ibx->smsg_eml($smsg) or return;
			return 1 if $chash eq content_hash($cmp);
		}
	}
	undef;
}

sub _spamcheck_cb {
	my ($sc) = @_;
	sub { # this gets called by (V2Writable||Import)->add
		my ($mime, $ibx) = @_;
		return if content_exists($ibx, $mime);
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

1;
