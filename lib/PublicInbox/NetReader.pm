# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# common reader code for IMAP and NNTP (and maybe JMAP)
package PublicInbox::NetReader;
use strict;
use v5.10.1;
use parent qw(Exporter PublicInbox::IPC);
use PublicInbox::Eml;
our %IMAPflags2kw = map {; "\\\u$_" => $_ } qw(seen answered flagged draft);
$IMAPflags2kw{'$Forwarded'} = 'forwarded';  # RFC 5550

our @EXPORT = qw(uri_section imap_uri nntp_uri);

sub ndump {
	require Data::Dumper;
	Data::Dumper->new(\@_)->Useqq(1)->Terse(1)->Dump;
}

# returns the git config section name, e.g [imap "imaps://user@example.com"]
# without the mailbox, so we can share connections between different inboxes
sub uri_section ($) {
	my ($uri) = @_;
	$uri->scheme . '://' . $uri->authority;
}

sub auth_anon_cb { '' }; # for Mail::IMAPClient::Authcallback

# mic_for may prompt the user and store auth info, prepares mic_get
sub mic_for { # mic = Mail::IMAPClient
	my ($self, $url, $mic_args, $lei) = @_;
	require PublicInbox::URIimap;
	my $uri = PublicInbox::URIimap->new($url);
	require PublicInbox::GitCredential;
	my $cred = bless {
		url => $url,
		protocol => $uri->scheme,
		host => $uri->host,
		username => $uri->user,
		password => $uri->password,
	}, 'PublicInbox::GitCredential';
	my $common = $mic_args->{uri_section($uri)} // {};
	# IMAPClient and Net::Netrc both mishandles `0', so we pass `127.0.0.1'
	my $host = $cred->{host};
	$host = '127.0.0.1' if $host eq '0';
	my $mic_arg = {
		Port => $uri->port,
		Server => $host,
		Ssl => $uri->scheme eq 'imaps',
		Keepalive => 1, # SO_KEEPALIVE
		%$common, # may set Starttls, Compress, Debug ....
	};
	require PublicInbox::IMAPClient;
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
		$cred->check_netrc unless defined $cred->{password};
		$cred->fill($lei); # may prompt user here
		$mic->User($mic_arg->{User} = $cred->{username});
		$mic->Password($mic_arg->{Password} = $cred->{password});
	} else { # AUTH=ANONYMOUS
		$mic->Authmechanism($mic_arg->{Authmechanism} = 'ANONYMOUS');
		$mic_arg->{Authcallback} = 'auth_anon_cb';
		$mic->Authcallback(\&auth_anon_cb);
	}
	my $err;
	if ($mic->login && $mic->IsAuthenticated) {
		# success! keep IMAPClient->new arg in case we get disconnected
		$self->{mic_arg}->{uri_section($uri)} = $mic_arg;
	} else {
		$err = "E: <$url> LOGIN: $@\n";
		if ($cred && defined($cred->{password})) {
			$err =~ s/\Q$cred->{password}\E/*******/g;
		}
		$mic = undef;
	}
	$cred->run($mic ? 'approve' : 'reject') if $cred;
	if ($err) {
		$lei ? $lei->fail($err) : warn($err);
	}
	$mic;
}

# Net::NNTP doesn't support CAPABILITIES, yet
sub try_starttls ($) {
	my ($host) = @_;
	return if $host =~ /\.onion\z/s;
	return if $host =~ /\A127\.[0-9]+\.[0-9]+\.[0-9]+\z/s;
	return if $host eq '::1';
	1;
}

sub nn_new ($$$) {
	my ($nn_arg, $nntp_opt, $uri) = @_;
	my $nn = Net::NNTP->new(%$nn_arg) or die "E: <$uri> new: $!\n";

	# default to using STARTTLS if it's available, but allow
	# it to be disabled for localhost/VPN users
	if (!$nn_arg->{SSL} && $nn->can('starttls')) {
		if (!defined($nntp_opt->{starttls}) &&
				try_starttls($nn_arg->{Host})) {
			# soft fail by default
			$nn->starttls or warn <<"";
W: <$uri> STARTTLS tried and failed (not requested)

		} elsif ($nntp_opt->{starttls}) {
			# hard fail if explicitly configured
			$nn->starttls or die <<"";
E: <$uri> STARTTLS requested and failed

		}
	} elsif ($nntp_opt->{starttls}) {
		$nn->can('starttls') or
			die "E: <$uri> Net::NNTP too old for STARTTLS\n";
		$nn->starttls or die <<"";
E: <$uri> STARTTLS requested and failed

	}
	$nn;
}

sub nn_for ($$$;$) { # nn = Net::NNTP
	my ($self, $uri, $nn_args, $lei) = @_;
	my $sec = uri_section($uri);
	my $nntp_opt = $self->{nntp_opt}->{$sec} //= {};
	my $host = $uri->host;
	# Net::NNTP and Net::Netrc both mishandle `0', so we pass `127.0.0.1'
	$host = '127.0.0.1' if $host eq '0';
	my $cred;
	my ($u, $p);
	if (defined(my $ui = $uri->userinfo)) {
		require PublicInbox::GitCredential;
		$cred = bless {
			url => $sec,
			protocol => $uri->scheme,
			host => $host,
		}, 'PublicInbox::GitCredential';
		($u, $p) = split(/:/, $ui, 2);
		($cred->{username}, $cred->{password}) = ($u, $p);
		$cred->check_netrc unless defined $p;
	}
	my $common = $nn_args->{$sec} // {};
	my $nn_arg = {
		Port => $uri->port,
		Host => $host,
		SSL => $uri->secure, # snews == nntps
		%$common, # may Debug ....
	};
	my $nn = nn_new($nn_arg, $nntp_opt, $uri);
	if ($cred) {
		$cred->fill($lei); # may prompt user here
		if ($nn->authinfo($u, $p)) {
			push @{$nntp_opt->{-postconn}}, [ 'authinfo', $u, $p ];
		} else {
			warn "E: <$uri> AUTHINFO $u XXXX failed\n";
			$nn = undef;
		}
	}

	if ($nntp_opt->{compress}) {
		# https://rt.cpan.org/Ticket/Display.html?id=129967
		if ($nn->can('compress')) {
			if ($nn->compress) {
				push @{$nntp_opt->{-postconn}}, [ 'compress' ];
			} else {
				warn "W: <$uri> COMPRESS failed\n";
			}
		} else {
			delete $nntp_opt->{compress};
			warn <<"";
W: <$uri> COMPRESS not supported by Net::NNTP
W: see https://rt.cpan.org/Ticket/Display.html?id=129967 for updates

		}
	}

	$self->{nn_arg}->{$sec} = $nn_arg;
	$cred->run($nn ? 'approve' : 'reject') if $cred;
	$nn;
}

sub imap_uri {
	my ($url) = @_;
	require PublicInbox::URIimap;
	my $uri = PublicInbox::URIimap->new($url);
	$uri ? $uri->canonical : undef;
}

my %IS_NNTP = (news => 1, snews => 1, nntp => 1, nntps => 1);
sub nntp_uri {
	my ($url) = @_;
	require PublicInbox::URInntps;
	my $uri = PublicInbox::URInntps->new($url);
	$uri && $IS_NNTP{$uri->scheme} && $uri->group ? $uri->canonical : undef;
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

sub cfg_bool ($$$) {
	my ($cfg, $key, $url) = @_;
	my $orig = $cfg->urlmatch($key, $url) // return;
	my $bool = $cfg->git_bool($orig);
	warn "W: $key=$orig for $url is not boolean\n" unless defined($bool);
	$bool;
}

# flesh out common IMAP-specific data structures
sub imap_common_init ($;$) {
	my ($self, $lei) = @_;
	return unless $self->{imap_order};
	$self->{quiet} = 1 if $lei && $lei->{opt}->{quiet};
	eval { require PublicInbox::IMAPClient } or
		die "Mail::IMAPClient is required for IMAP:\n$@\n";
	eval { require PublicInbox::IMAPTracker } or
		die "DBD::SQLite is required for IMAP\n:$@\n";
	require PublicInbox::URIimap;
	my $cfg = $self->{pi_cfg} // $lei->_lei_cfg;
	my $mic_args = {}; # scheme://authority => Mail:IMAPClient arg
	for my $uri (@{$self->{imap_order}}) {
		my $sec = uri_section($uri);
		for my $k (qw(Starttls Debug Compress)) {
			my $bool = cfg_bool($cfg, "imap.$k", $$uri) // next;
			$mic_args->{$sec}->{$k} = $bool;
		}
		my $to = cfg_intvl($cfg, 'imap.timeout', $$uri);
		$mic_args->{$sec}->{Timeout} = $to if $to;
		for my $k (qw(pollInterval idleInterval)) {
			$to = cfg_intvl($cfg, "imap.$k", $$uri) // next;
			$self->{imap_opt}->{$sec}->{$k} = $to;
		}
		my $k = 'imap.fetchBatchSize';
		my $bs = $cfg->urlmatch($k, $$uri) // next;
		if ($bs =~ /\A([0-9]+)\z/) {
			$self->{imap_opt}->{$sec}->{batch_size} = $bs;
		} else {
			warn "$k=$bs is not an integer\n";
		}
	}
	# make sure we can connect and cache the credentials in memory
	$self->{mic_arg} = {}; # schema://authority => IMAPClient->new args
	my $mics = {}; # schema://authority => IMAPClient obj
	for my $uri (@{$self->{imap_order}}) {
		my $sec = uri_section($uri);
		my $mic = $mics->{$sec} //=
				mic_for($self, "$sec/", $mic_args, $lei) //
				die "Unable to continue\n";
		next unless $self->isa('PublicInbox::NetWriter');
		my $dst = $uri->mailbox // next;
		next if $mic->exists($dst); # already exists
		$mic->create($dst) or die "CREATE $dst failed <$uri>: $@";
	}
	$mics;
}

# flesh out common NNTP-specific data structures
sub nntp_common_init ($;$) {
	my ($self, $lei) = @_;
	return unless $self->{nntp_order};
	$self->{quiet} = 1 if $lei && $lei->{opt}->{quiet};
	eval { require Net::NNTP } or
		die "Net::NNTP is required for NNTP:\n$@\n";
	eval { require PublicInbox::IMAPTracker } or
		die "DBD::SQLite is required for NNTP\n:$@\n";
	my $cfg = $self->{pi_cfg} // $lei->_lei_cfg;
	my $nn_args = {}; # scheme://authority => Net::NNTP->new arg
	for my $uri (@{$self->{nntp_order}}) {
		my $sec = uri_section($uri);

		# Debug and Timeout are passed to Net::NNTP->new
		my $v = cfg_bool($cfg, 'nntp.Debug', $$uri);
		$nn_args->{$sec}->{Debug} = $v if defined $v;
		my $to = cfg_intvl($cfg, 'nntp.Timeout', $$uri);
		$nn_args->{$sec}->{Timeout} = $to if $to;

		# Net::NNTP post-connect commands
		for my $k (qw(starttls compress)) {
			$v = cfg_bool($cfg, "nntp.$k", $$uri) // next;
			$self->{nntp_opt}->{$sec}->{$k} = $v;
		}

		# internal option
		for my $k (qw(pollInterval)) {
			$to = cfg_intvl($cfg, "nntp.$k", $$uri) // next;
			$self->{nntp_opt}->{$sec}->{$k} = $to;
		}
	}
	# make sure we can connect and cache the credentials in memory
	$self->{nn_arg} = {}; # schema://authority => Net::NNTP->new args
	my %nn; # schema://authority => Net::NNTP object
	for my $uri (@{$self->{nntp_order}}) {
		my $sec = uri_section($uri);
		$nn{$sec} //= nn_for($self, $uri, $nn_args, $lei);
	}
	\%nn; # for optional {nn_cached}
}

sub add_url {
	my ($self, $arg) = @_;
	my $uri;
	if ($uri = imap_uri($arg)) {
		push @{$self->{imap_order}}, $uri;
	} elsif ($uri = nntp_uri($arg)) {
		push @{$self->{nntp_order}}, $uri;
	} else {
		push @{$self->{unsupported_url}}, $arg;
	}
}

sub errors {
	my ($self) = @_;
	if (my $u = $self->{unsupported_url}) {
		return "Unsupported URL(s): @$u";
	}
	if ($self->{imap_order}) {
		eval { require PublicInbox::IMAPClient } or
			die "Mail::IMAPClient is required for IMAP:\n$@\n";
	}
	if ($self->{nntp_order}) {
		eval { require Net::NNTP } or
			die "Net::NNTP is required for NNTP:\n$@\n";
	}
	undef;
}

sub _imap_do_msg ($$$$$) {
	my ($self, $uri, $uid, $raw, $flags) = @_;
	# our target audience expects LF-only, save storage
	$$raw =~ s/\r\n/\n/sg;
	my $kw = [];
	for my $f (split(/ /, $flags)) {
		if (my $k = $IMAPflags2kw{$f}) {
			push @$kw, $k;
		} elsif ($f eq "\\Recent") { # not in JMAP
		} elsif ($f eq "\\Deleted") { # not in JMAP
			return;
		} elsif ($self->{verbose}) {
			warn "# unknown IMAP flag $f <$uri;uid=$uid>\n";
		}
	}
	@$kw = sort @$kw; # for all UI/UX purposes
	my ($eml_cb, @args) = @{$self->{eml_each}};
	$eml_cb->($uri, $uid, $kw, PublicInbox::Eml->new($raw), @args);
}

sub run_commit_cb ($) {
	my ($self) = @_;
	my $cmt_cb_args = $self->{on_commit} or return;
	my ($cb, @args) = @$cmt_cb_args;
	$cb->(@args);
}

sub _itrk ($$) {
	my ($self, $uri) = @_;
	return unless $self->{incremental};
	# itrk_fn is set by lei
	PublicInbox::IMAPTracker->new($$uri, $self->{itrk_fn});
}

sub _imap_fetch_all ($$$) {
	my ($self, $mic, $uri) = @_;
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
		return "E: $uri cannot get UIDVALIDITY";
	$r_uidnext //= $mic->uidnext($mbx) //
		return "E: $uri cannot get UIDNEXT";
	my $itrk = _itrk($self, $uri);
	my $l_uid;
	$l_uid = $itrk->get_last($r_uidval) if $itrk;
	$l_uid //= 0;
	my $r_uid = $r_uidnext - 1;
	if ($l_uid > $r_uid) {
		return "E: $uri local UID exceeds remote ($l_uid > $r_uid)\n";
	}
	return if $l_uid >= $r_uid; # nothing to do
	$l_uid ||= 1;
	my ($mod, $shard) = @{$self->{shard_info} // []};
	unless ($self->{quiet}) {
		my $m = $mod ? " [(UID % $mod) == $shard]" : '';
		warn "# $uri fetching UID $l_uid:$r_uid$m\n";
	}
	$mic->Uid(1); # the default, we hope
	my $bs = $self->{imap_opt}->{$sec}->{batch_size} // 1;
	my $req = $mic->imap4rev1 ? 'BODY.PEEK[]' : 'RFC822.PEEK';
	my $key = $req;
	$key =~ s/\.PEEK//;
	my ($uids, $batch);
	my $err;
	do {
		# I wish "UID FETCH $START:*" could work, but:
		# 1) servers do not need to return results in any order
		# 2) Mail::IMAPClient doesn't offer a streaming API
		unless ($uids = $mic->search("UID $l_uid:*")) {
			return if $!{EINTR} && $self->{quit};
			return "E: $uri UID SEARCH $l_uid:* error: $!";
		}
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

		@$uids = grep { ($_ % $mod) == $shard } @$uids if $mod;
		while (scalar @$uids) {
			my @batch = splice(@$uids, 0, $bs);
			$batch = join(',', @batch);
			local $0 = "UID:$batch $mbx $sec";
			my $r = $mic->fetch_hash($batch, $req, 'FLAGS');
			unless ($r) { # network error?
				last if $!{EINTR} && $self->{quit};
				$err = "E: $uri UID FETCH $batch error: $!";
				last;
			}
			for my $uid (@batch) {
				# messages get deleted, so holes appear
				my $per_uid = delete $r->{$uid} // next;
				my $raw = delete($per_uid->{$key}) // next;
				_imap_do_msg($self, $uri, $uid, \$raw,
						$per_uid->{FLAGS});
				$last_uid = $uid;
				last if $self->{quit};
			}
			last if $self->{quit};
		}
		run_commit_cb($self);
		$itrk->update_last($r_uidval, $last_uid) if $itrk;
	} until ($err || $self->{quit});
	$err;
}

# uses cached auth info prepared by mic_for
sub mic_get {
	my ($self, $uri) = @_;
	my $sec = uri_section($uri);
	# see if caller saved result of imap_common_init
	my $cached = $self->{mics_cached};
	if ($cached) {
		my $mic = $cached->{$sec};
		return $mic if $mic && $mic->IsConnected;
		delete $cached->{$sec};
	}
	my $mic_arg = $self->{mic_arg}->{$sec} or
			die "BUG: no Mail::IMAPClient->new arg for $sec";
	if (defined(my $cb_name = $mic_arg->{Authcallback})) {
		if (ref($cb_name) ne 'CODE') {
			$mic_arg->{Authcallback} = $self->can($cb_name);
		}
	}
	my $mic = PublicInbox::IMAPClient->new(%$mic_arg);
	$cached //= {}; # invalid placeholder if no cache enabled
	$mic && $mic->IsConnected ? ($cached->{$sec} = $mic) : undef;
}

sub imap_each {
	my ($self, $url, $eml_cb, @args) = @_;
	my $uri = ref($url) ? $url : PublicInbox::URIimap->new($url);
	my $sec = uri_section($uri);
	local $0 = $uri->mailbox." $sec";
	my $mic = mic_get($self, $uri);
	my $err;
	if ($mic) {
		local $self->{eml_each} = [ $eml_cb, @args ];
		$err = _imap_fetch_all($self, $mic, $uri);
	} else {
		$err = "E: <$uri> not connected: $!";
	}
	warn $err if $err;
	$mic;
}

# may used cached auth info prepared by nn_for once
sub nn_get {
	my ($self, $uri) = @_;
	my $sec = uri_section($uri);
	# see if caller saved result of nntp_common_init
	my $cached = $self->{nn_cached} // {};
	my $nn;
	$nn = delete($cached->{$sec}) and return $nn;
	my $nn_arg = $self->{nn_arg}->{$sec} or
			die "BUG: no Net::NNTP->new arg for $sec";
	my $nntp_opt = $self->{nntp_opt}->{$sec};
	$nn = nn_new($nn_arg, $nntp_opt, $uri) or return;
	if (my $postconn = $nntp_opt->{-postconn}) {
		for my $m_arg (@$postconn) {
			my ($method, @args) = @$m_arg;
			$nn->$method(@args) and next;
			die "E: <$uri> $method failed\n";
			return;
		}
	}
	$nn;
}

sub _nntp_fetch_all ($$$) {
	my ($self, $nn, $uri) = @_;
	my ($group, $num_a, $num_b) = $uri->group;
	my $sec = uri_section($uri);
	my ($nr, $beg, $end) = $nn->group($group);
	unless (defined($nr)) {
		my $msg = ndump($nn->message);
		return "E: GROUP $group <$sec> $msg";
	}

	# IMAPTracker is also used for tracking NNTP, UID == article number
	# LIST.ACTIVE can get the equivalent of UIDVALIDITY, but that's
	# expensive.  So we assume newsgroups don't change:
	my $itrk = _itrk($self, $uri);
	my (undef, $l_art) = $itrk ? $itrk->get_last : ();

	# allow users to specify articles to refetch
	# cf. https://tools.ietf.org/id/draft-gilman-news-url-01.txt
	# nntp://example.com/inbox.foo/$num_a-$num_b
	$beg = $num_a if defined($num_a) && $num_a < $beg;
	$end = $num_b if defined($num_b) && $num_b < $end;
	if (defined $l_art) {
		return if $l_art >= $end; # nothing to do
		$beg = $l_art + 1;
	}
	my ($err, $art, $last_art, $kw); # kw stays undef, no keywords in NNTP
	unless ($self->{quiet}) {
		warn "# $uri fetching ARTICLE $beg..$end\n";
	}
	my $n = $self->{max_batch};
	for ($beg..$end) {
		last if $self->{quit};
		$art = $_;
		if (--$n < 0) {
			run_commit_cb($self);
			$itrk->update_last(0, $last_art) if $itrk;
			$n = $self->{max_batch};
		}
		my $raw = $nn->article($art);
		unless (defined($raw)) {
			my $msg = ndump($nn->message);
			if ($nn->code == 421) { # pseudo response from Net::Cmd
				$err = "E: $msg";
				last;
			} else { # probably just a deleted message (spam)
				warn "W: $msg";
				next;
			}
		}
		$raw = join('', @$raw);
		$raw =~ s/\r\n/\n/sg;
		my ($eml_cb, @args) = @{$self->{eml_each}};
		$eml_cb->($uri, $art, $kw, PublicInbox::Eml->new(\$raw), @args);
		$last_art = $art;
	}
	run_commit_cb($self);
	$itrk->update_last(0, $last_art) if $itrk;
	$err;
}

sub nntp_each {
	my ($self, $url, $eml_cb, @args) = @_;
	my $uri = ref($url) ? $url : PublicInbox::URInntps->new($url);
	my $sec = uri_section($uri);
	local $0 = $uri->group ." $sec";
	my $nn = nn_get($self, $uri);
	return if $self->{quit};
	my $err;
	if ($nn) {
		local $self->{eml_each} = [ $eml_cb, @args ];
		$err = _nntp_fetch_all($self, $nn, $uri);
	} else {
		$err = "E: <$uri> not connected: $!";
	}
	warn $err if $err;
	$nn;
}

sub new { bless {}, shift };

1;
