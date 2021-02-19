# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# common reader code for IMAP and NNTP (and maybe JMAP)
package PublicInbox::NetReader;
use strict;
use v5.10.1;
use parent qw(Exporter PublicInbox::IPC);
use PublicInbox::Eml;

# TODO: trim this down, this is huge
our @EXPORT = qw(uri_new uri_scheme uri_section
		mic_for nn_new nn_for
		imap_url nntp_url
		cfg_bool cfg_intvl imap_common_init
		);

# avoid exposing deprecated "snews" to users.
my %SCHEME_MAP = ('snews' => 'nntps');

sub uri_scheme ($) {
	my ($uri) = @_;
	my $scheme = $uri->scheme;
	$SCHEME_MAP{$scheme} // $scheme;
}

# returns the git config section name, e.g [imap "imaps://user@example.com"]
# without the mailbox, so we can share connections between different inboxes
sub uri_section ($) {
	my ($uri) = @_;
	uri_scheme($uri) . '://' . $uri->authority;
}

sub auth_anon_cb { '' }; # for Mail::IMAPClient::Authcallback

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

sub uri_new {
	my ($url) = @_;
	require URI;

	# URI::snews exists, URI::nntps does not, so use URI::snews
	$url =~ s!\Anntps://!snews://!i;
	URI->new($url);
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
	my ($nn_arg, $nntp_opt, $url) = @_;
	my $nn = Net::NNTP->new(%$nn_arg) or die "E: <$url> new: $!\n";

	# default to using STARTTLS if it's available, but allow
	# it to be disabled for localhost/VPN users
	if (!$nn_arg->{SSL} && $nn->can('starttls')) {
		if (!defined($nntp_opt->{starttls}) &&
				try_starttls($nn_arg->{Host})) {
			# soft fail by default
			$nn->starttls or warn <<"";
W: <$url> STARTTLS tried and failed (not requested)

		} elsif ($nntp_opt->{starttls}) {
			# hard fail if explicitly configured
			$nn->starttls or die <<"";
E: <$url> STARTTLS requested and failed

		}
	} elsif ($nntp_opt->{starttls}) {
		$nn->can('starttls') or
			die "E: <$url> Net::NNTP too old for STARTTLS\n";
		$nn->starttls or die <<"";
E: <$url> STARTTLS requested and failed

	}
	$nn;
}

sub nn_for ($$$;$) { # nn = Net::NNTP
	my ($self, $url, $nn_args, $lei) = @_;
	my $uri = uri_new($url);
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
			protocol => uri_scheme($uri),
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
	my $nn = nn_new($nn_arg, $nntp_opt, $url);

	if ($cred) {
		$cred->fill($lei); # may prompt user here
		if ($nn->authinfo($u, $p)) {
			push @{$nntp_opt->{-postconn}}, [ 'authinfo', $u, $p ];
		} else {
			warn "E: <$url> AUTHINFO $u XXXX failed\n";
			$nn = undef;
		}
	}

	if ($nntp_opt->{compress}) {
		# https://rt.cpan.org/Ticket/Display.html?id=129967
		if ($nn->can('compress')) {
			if ($nn->compress) {
				push @{$nntp_opt->{-postconn}}, [ 'compress' ];
			} else {
				warn "W: <$url> COMPRESS failed\n";
			}
		} else {
			delete $nntp_opt->{compress};
			warn <<"";
W: <$url> COMPRESS not supported by Net::NNTP
W: see https://rt.cpan.org/Ticket/Display.html?id=129967 for updates

		}
	}

	$self->{nn_arg}->{$sec} = $nn_arg;
	$cred->run($nn ? 'approve' : 'reject') if $cred;
	$nn;
}

sub imap_url {
	my ($url) = @_;
	require PublicInbox::URIimap;
	my $uri = PublicInbox::URIimap->new($url);
	$uri ? $uri->canonical->as_string : undef;
}

my %IS_NNTP = (news => 1, snews => 1, nntp => 1);
sub nntp_url {
	my ($url) = @_;
	my $uri = uri_new($url);
	return unless $uri && $IS_NNTP{$uri->scheme} && $uri->group;
	$url = $uri->canonical->as_string;
	# nntps is IANA registered, snews is deprecated
	$url =~ s!\Asnews://!nntps://!;
	$url;
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
	$self->{quiet} = 1 if $lei && $lei->{opt}->{quiet};
	eval { require PublicInbox::IMAPClient } or
		die "Mail::IMAPClient is required for IMAP:\n$@\n";
	eval { require PublicInbox::IMAPTracker } or
		die "DBD::SQLite is required for IMAP\n:$@\n";
	require PublicInbox::URIimap;
	my $cfg = $self->{pi_cfg} // $lei->_lei_cfg;
	my $mic_args = {}; # scheme://authority => Mail:IMAPClient arg
	for my $url (@{$self->{imap_order}}) {
		my $uri = PublicInbox::URIimap->new($url);
		my $sec = uri_section($uri);
		for my $k (qw(Starttls Debug Compress)) {
			my $bool = cfg_bool($cfg, "imap.$k", $url) // next;
			$mic_args->{$sec}->{$k} = $bool;
		}
		my $to = cfg_intvl($cfg, 'imap.timeout', $url);
		$mic_args->{$sec}->{Timeout} = $to if $to;
		for my $k (qw(pollInterval idleInterval)) {
			$to = cfg_intvl($cfg, "imap.$k", $url) // next;
			$self->{imap_opt}->{$sec}->{$k} = $to;
		}
		my $k = 'imap.fetchBatchSize';
		my $bs = $cfg->urlmatch($k, $url) // next;
		if ($bs =~ /\A([0-9]+)\z/) {
			$self->{imap_opt}->{$sec}->{batch_size} = $bs;
		} else {
			warn "$k=$bs is not an integer\n";
		}
	}
	# make sure we can connect and cache the credentials in memory
	$self->{mic_arg} = {}; # schema://authority => IMAPClient->new args
	my $mics = {}; # schema://authority => IMAPClient obj
	for my $url (@{$self->{imap_order}}) {
		my $uri = PublicInbox::URIimap->new($url);
		my $sec = uri_section($uri);
		$mics->{$sec} //= mic_for($self, $url, $mic_args, $lei);
	}
	$mics;
}

sub add_url {
	my ($self, $arg) = @_;
	if (my $url = imap_url($arg)) {
		push @{$self->{imap_order}}, $url;
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
	undef;
}

my %IMAPflags2kw = (
	'\Seen' => 'seen',
	'\Answered' => 'answered',
	'\Flagged' => 'flagged',
	'\Draft' => 'draft',
);

sub _imap_do_msg ($$$$$) {
	my ($self, $url, $uid, $raw, $flags) = @_;
	# our target audience expects LF-only, save storage
	$$raw =~ s/\r\n/\n/sg;
	my $kw = [];
	for my $f (split(/ /, $flags)) {
		my $k = $IMAPflags2kw{$f} // next; # TODO: X-Label?
		push @$kw, $k;
	}
	my ($eml_cb, @args) = @{$self->{eml_each}};
	$eml_cb->($url, $uid, $kw, PublicInbox::Eml->new($raw), @args);
}

sub _imap_fetch_all ($$$) {
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
	my $itrk = $self->{incremental} ?
			PublicInbox::IMAPTracker->new($url) : 0;
	my ($l_uidval, $l_uid) = $itrk ? $itrk->get_last : ();
	$l_uidval //= $r_uidval; # first time
	$l_uid //= 0;
	if ($l_uidval != $r_uidval) {
		return "E: $url UIDVALIDITY mismatch\n".
			"E: local=$l_uidval != remote=$r_uidval";
	}
	my $r_uid = $r_uidnext - 1;
	if ($l_uid > $r_uid) {
		return "E: $url local UID exceeds remote ($l_uid > $r_uid)\n".
			"E: $url strangely, UIDVALIDLITY matches ($l_uidval)\n";
	}
	return if $l_uid >= $r_uid; # nothing to do
	$l_uid ||= 1;

	warn "# $url fetching UID $l_uid:$r_uid\n" unless $self->{quiet};
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
				_imap_do_msg($self, $url, $uid, \$raw,
						$per_uid->{FLAGS});
				$last_uid = $uid;
				last if $self->{quit};
			}
			last if $self->{quit};
		}
		$itrk->update_last($r_uidval, $last_uid) if $itrk;
	} until ($err || $self->{quit});
	$err;
}

sub imap_each {
	my ($self, $url, $eml_cb, @args) = @_;
	my $uri = PublicInbox::URIimap->new($url);
	my $sec = uri_section($uri);
	my $mic_arg = $self->{mic_arg}->{$sec} or
			die "BUG: no Mail::IMAPClient->new arg for $sec";
	local $0 = $uri->mailbox." $sec";
	my $cb_name = $mic_arg->{Authcallback};
	if (ref($cb_name) ne 'CODE') {
		$mic_arg->{Authcallback} = $self->can($cb_name);
	}
	my $mic = PublicInbox::IMAPClient->new(%$mic_arg, Debug => 0);
	my $err;
	if ($mic && $mic->IsConnected) {
		local $self->{eml_each} = [ $eml_cb, @args ];
		$err = _imap_fetch_all($self, $mic, $url);
	} else {
		$err = "E: not connected: $!";
	}
	$mic;
}

sub new { bless {}, shift };

1;