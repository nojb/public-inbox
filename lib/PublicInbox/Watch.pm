# Copyright (C) 2016-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# ref: https://cr.yp.to/proto/maildir.html
#	https://wiki2.dovecot.org/MailboxFormat/Maildir
package PublicInbox::Watch;
use strict;
use v5.10.1;
use PublicInbox::Eml;
use PublicInbox::InboxWritable qw(eml_from_path);
use PublicInbox::MdirReader;
use PublicInbox::NetReader;
use PublicInbox::Filter::Base qw(REJECT);
use PublicInbox::Spamcheck;
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
	my (@imap, @nntp);

	# "publicinboxwatch" is the documented namespace
	# "publicinboxlearn" is legacy but may be supported
	# indefinitely...
	foreach my $pfx (qw(publicinboxwatch publicinboxlearn)) {
		my $k = "$pfx.watchspam";
		my $dirs = $cfg->get_all($k) // next;
		for my $dir (@$dirs) {
			my $uri;
			if (is_maildir($dir)) {
				# skip "new", no MUA has seen it, yet.
				$mdmap{"$dir/cur"} = 'watchspam';
			} elsif ($uri = imap_uri($dir)) {
				$imap{$$uri} = 'watchspam';
				push @imap, $uri;
			} elsif ($uri = nntp_uri($dir)) {
				$nntp{$$uri} = 'watchspam';
				push @nntp, $uri;
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
			my $uri;
			if (is_maildir($watch)) {
				compile_watchheaders($ibx);
				my ($new, $cur) = ("$watch/new", "$watch/cur");
				my $cur_dst = $mdmap{$cur} //= [];
				return if is_watchspam($cur, $cur_dst, $ibx);
				push @{$mdmap{$new} //= []}, $ibx;
				push @$cur_dst, $ibx;
			} elsif ($uri = imap_uri($watch)) {
				my $cur_dst = $imap{$$uri} //= [];
				return if is_watchspam($uri, $cur_dst, $ibx);
				compile_watchheaders($ibx);
				push(@imap, $uri) if 1 == push(@$cur_dst, $ibx);
			} elsif ($uri = nntp_uri($watch)) {
				my $cur_dst = $nntp{$$uri} //= [];
				return if is_watchspam($uri, $cur_dst, $ibx);
				compile_watchheaders($ibx);
				push(@nntp, $uri) if 1 == push(@$cur_dst, $ibx);
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
		imap_order => scalar(@imap) ? \@imap : undef,
		nntp_order => scalar(@nntp) ? \@nntp: undef,
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
	my $dir_idle = PublicInbox::DirIdle->new($cb);
	$dir_idle->add_watches([keys %{$self->{mdmap}}]);
}

sub net_cb { # NetReader::(nntp|imap)_each callback
	my ($uri, $art, $kw, $eml, $self, $inboxes) = @_;
	return if grep(/\Adraft\z/, @$kw);
	local $self->{cur_uid} = $art; # IMAP UID or NNTP article
	if (ref($inboxes)) {
		my @ibx = @$inboxes;
		my $last = pop @ibx;
		for my $ibx (@ibx) {
			my $tmp = PublicInbox::Eml->new(\($eml->as_string));
			import_eml($self, $ibx, $tmp);
		}
		import_eml($self, $last, $eml);
	} elsif ($inboxes eq 'watchspam') {
		if ($uri->scheme =~ /\Aimaps?\z/ && !grep(/\Aseen\z/, @$kw)) {
			return;
		}
		$self->{pi_cfg}->each_inbox(\&remove_eml_i,
				$self, $eml, "$uri #$art");
	} else {
		die "BUG: destination unknown $inboxes";
	}
}

sub imap_fetch_all ($$) {
	my ($self, $uri) = @_;
	my $warn_cb = $SIG{__WARN__} || \&CORE::warn;
	$self->{incremental} = 1;
	$self->{on_commit} = [ \&_done_for_now, $self ];
	local $self->{cur_uid};
	local $SIG{__WARN__} = sub {
		my $pfx = ($_[0] // '') =~ /^([A-Z]: |# )/g ? $1 : '';
		my $uid = $self->{cur_uid};
		$warn_cb->("$pfx$uri", $uid ? ("UID:$uid") : (), "\n", @_);
	};
	PublicInbox::NetReader::imap_each($self, $uri, \&net_cb, $self,
					$self->{imap}->{$$uri});
}

sub imap_idle_once ($$$$) {
	my ($self, $mic, $intvl, $uri) = @_;
	my $i = $intvl //= (29 * 60);
	my $end = now() + $intvl;
	warn "I: $uri idling for ${intvl}s\n";
	local $0 = "IDLE $0";
	return if $self->{quit};
	unless ($mic->idle) {
		return if $self->{quit};
		return "E: IDLE failed on $uri: $!";
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
		$mic->IsConnected or return "E: IDLE disconnected on $uri";
		$mic->done or return "E: IDLE DONE failed on $uri: $!";
	}
	undef;
}

# idles on a single URI
sub watch_imap_idle_1 ($$$) {
	my ($self, $uri, $intvl) = @_;
	my $sec = uri_section($uri);
	my $mic_arg = $self->{net_arg}->{$sec} or
			die "BUG: no Mail::IMAPClient->new arg for $sec";
	my $mic;
	local $0 = $uri->mailbox." $sec";
	until ($self->{quit}) {
		$mic //= PublicInbox::NetReader::mic_new(
					$self, $mic_arg, $sec, $uri);
		my $err;
		if ($mic && $mic->IsConnected) {
			local $self->{mics_cached}->{$sec} = $mic;
			my $m = imap_fetch_all($self, $uri);
			$m == $mic or die "BUG: wrong mic";
			$mic->IsConnected and
				$err = imap_idle_once($self, $mic, $intvl, $uri)
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
	my $sig = delete $self->{sig};
	$sig->{CHLD} = 'DEFAULT';
	@SIG{keys %$sig} = values %$sig;
	PublicInbox::DS::sig_setmask($self->{oldset});
}

sub watch_atfork_parent ($) {
	my ($self) = @_;
	_done_for_now($self);
	PublicInbox::DS::block_signals();
}

sub imap_idle_requeue { # DS::add_timer callback
	my ($self, $uri_intvl) = @_;
	return if $self->{quit};
	push @{$self->{idle_todo}}, $uri_intvl;
	event_step($self);
}

sub imap_idle_reap { # PublicInbox::DS::dwaitpid callback
	my ($self, $pid) = @_;
	my $uri_intvl = delete $self->{idle_pids}->{$pid} or
		die "BUG: PID=$pid (unknown) reaped: \$?=$?\n";

	my ($uri, $intvl) = @$uri_intvl;
	return if $self->{quit};
	warn "W: PID=$pid on $uri died: \$?=$?\n" if $?;
	add_timer(60, \&imap_idle_requeue, $self, $uri_intvl);
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
	my ($self, $uri_intvl) = @_;
	my ($uri, $intvl) = @$uri_intvl;
	pipe(my ($r, $w)) or die "pipe: $!";
	my $seed = rand(0xffffffff);
	my $pid = fork // die "fork: $!";
	if ($pid == 0) {
		srand($seed);
		eval { Net::SSLeay::randomize() };
		close $r;
		watch_atfork_child($self);
		watch_imap_idle_1($self, $uri, $intvl);
		close $w;
		_exit(0);
	}
	$self->{idle_pids}->{$pid} = $uri_intvl;
	PublicInbox::EOFpipe->new($r, \&reap, [$pid, \&imap_idle_reap, $self]);
}

sub event_step {
	my ($self) = @_;
	return if $self->{quit};
	my $idle_todo = $self->{idle_todo};
	if ($idle_todo && @$idle_todo) {
		my $oldset = watch_atfork_parent($self);
		eval {
			while (my $uri_intvl = shift(@$idle_todo)) {
				imap_idle_fork($self, $uri_intvl);
			}
		};
		PublicInbox::DS::sig_setmask($oldset);
		die $@ if $@;
	}
	fs_scan_step($self) if $self->{mdre};
}

sub watch_imap_fetch_all ($$) {
	my ($self, $uris) = @_;
	for my $uri (@$uris) {
		imap_fetch_all($self, $uri);
		last if $self->{quit};
	}
}

sub watch_nntp_fetch_all ($$) {
	my ($self, $uris) = @_;
	$self->{incremental} = 1;
	$self->{on_commit} = [ \&_done_for_now, $self ];
	my $warn_cb = $SIG{__WARN__} || \&CORE::warn;
	local $self->{cur_uid};
	my $uri = '';
	local $SIG{__WARN__} = sub {
		my $pfx = ($_[0] // '') =~ /^([A-Z]: |# )/g ? $1 : '';
		my $art = $self->{cur_uid};
		$warn_cb->("$pfx$uri", $art ? ("ARTICLE $art") : (), "\n", @_);
	};
	for $uri (@$uris) {
		PublicInbox::NetReader::nntp_each($self, $uri, \&net_cb, $self,
					$self->{nntp}->{$$uri});
		last if $self->{quit};
	}
}

sub poll_fetch_fork { # DS::add_timer callback
	my ($self, $intvl, $uris) = @_;
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
		if ($uris->[0]->scheme =~ m!\Aimaps?!i) {
			watch_imap_fetch_all($self, $uris);
		} else {
			watch_nntp_fetch_all($self, $uris);
		}
		close $w;
		_exit(0);
	}
	PublicInbox::DS::sig_setmask($oldset);
	die "fork: $!"  unless defined $pid;
	$self->{poll_pids}->{$pid} = [ $intvl, $uris ];
	PublicInbox::EOFpipe->new($r, \&reap, [$pid, \&poll_fetch_reap, $self]);
}

sub poll_fetch_reap {
	my ($self, $pid) = @_;
	my $intvl_uris = delete $self->{poll_pids}->{$pid} or
		die "BUG: PID=$pid (unknown) reaped: \$?=$?\n";
	return if $self->{quit};
	my ($intvl, $uris) = @$intvl_uris;
	if ($?) {
		warn "W: PID=$pid died: \$?=$?\n", map { "$_\n" } @$uris;
	}
	warn("I: will check $_ in ${intvl}s\n") for @$uris;
	add_timer($intvl, \&poll_fetch_fork, $self, $intvl, $uris);
}

sub watch_imap_init ($$) {
	my ($self, $poll) = @_;
	my $mics = PublicInbox::NetReader::imap_common_init($self);
	my $idle = []; # [ [ uri1, intvl1 ], [uri2, intvl2] ]
	for my $uri (@{$self->{imap_order}}) {
		my $sec = uri_section($uri);
		my $mic = $mics->{$sec};
		my $intvl = $self->{cfg_opt}->{$sec}->{pollInterval};
		if ($mic->has_capability('IDLE') && !$intvl) {
			$intvl = $self->{cfg_opt}->{$sec}->{idleInterval};
			push @$idle, [ $uri, $intvl // () ];
		} else {
			push @{$poll->{$intvl || 120}}, $uri;
		}
	}
	if (scalar @$idle) {
		$self->{idle_todo} = $idle;
		PublicInbox::DS::requeue($self); # ->event_step to fork
	}
}

sub watch_nntp_init ($$) {
	my ($self, $poll) = @_;
	PublicInbox::NetReader::nntp_common_init($self);
	for my $uri (@{$self->{nntp_order}}) {
		my $sec = uri_section($uri);
		my $intvl = $self->{cfg_opt}->{$sec}->{pollInterval};
		push @{$poll->{$intvl || 120}}, $uri;
	}
}

sub watch { # main entry point
	my ($self, $sig, $oldset) = @_;
	$self->{oldset} = $oldset;
	$self->{sig} = $sig;
	my $poll = {}; # intvl_seconds => [ uri1, uri2 ]
	watch_imap_init($self, $poll) if $self->{imap};
	watch_nntp_init($self, $poll) if $self->{nntp};
	while (my ($intvl, $uris) = each %$poll) {
		# poll all URIs for a given interval sequentially
		add_timer(0, \&poll_fetch_fork, $self, $intvl, $uris);
	}
	watch_fs_init($self) if $self->{mdre};
	PublicInbox::DS->SetPostLoopCallback(sub { !$self->quit_done });
	PublicInbox::DS::event_loop($sig, $oldset); # calls ->event_step
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

sub folder_select { 'select' } # for PublicInbox::NetReader

1;
