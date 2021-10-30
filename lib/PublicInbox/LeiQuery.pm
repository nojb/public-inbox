# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# handles "lei q" command and provides internals for
# several other sub-commands (up, lcat, ...)
package PublicInbox::LeiQuery;
use strict;
use v5.10.1;

sub prep_ext { # externals_each callback
	my ($lxs, $exclude, $loc) = @_;
	$lxs->prepare_external($loc) unless $exclude->{$loc};
}

sub _start_query { # used by "lei q" and "lei up"
	my ($self) = @_;
	require PublicInbox::LeiOverview;
	PublicInbox::LeiOverview->new($self) or return;
	my $opt = $self->{opt};
	my ($xj, $mj) = split(/,/, $opt->{jobs} // '');
	(defined($xj) && $xj ne '' && $xj !~ /\A[1-9][0-9]*\z/) and
		die "`$xj' search jobs must be >= 1\n";
	my $lxs = $self->{lxs};
	$xj ||= $lxs->concurrency($opt); # allow: "--jobs ,$WRITER_ONLY"
	my $nproc = $lxs->detect_nproc || 1; # don't memoize, schedtool(1) exists
	$xj = $nproc if $xj > $nproc;
	$lxs->{-wq_nr_workers} = $xj;
	(defined($mj) && $mj !~ /\A[1-9][0-9]*\z/) and
		die "`$mj' writer jobs must be >= 1\n";
	my $l2m = $self->{l2m};
	# we use \1 (a ref) to distinguish between default vs. user-supplied
	if ($l2m && grep { $opt->{$_} //= \1 } (qw(mail-sync import-remote
							import-before))) {
		$self->_lei_store(1)->write_prepare($self);
		if ($opt->{'mail-sync'}) {
			my $lms = $l2m->{-lms_rw} = $self->lms(1);
			$lms->lms_write_prepare->lms_pause; # just create
		}
	}
	$l2m and $l2m->{-wq_nr_workers} //= $mj //
		int($nproc * 0.75 + 0.5); # keep some CPU for git

	# descending docid order is cheapest, MUA controls sorting order
	$self->{mset_opt}->{relevance} //= -2 if $l2m || $opt->{threads};

	my $tot = $self->{mset_opt}->{total} //= $self->{opt}->{limit} // 10000;
	$self->{mset_opt}->{limit} = $tot > 10000 ? 10000 : $tot;
	$self->{mset_opt}->{offset} //= 0;
	$self->{mset_opt}->{threads} //= $opt->{threads};

	if ($self->{net}) {
		require PublicInbox::LeiAuth;
		$self->{auth} = PublicInbox::LeiAuth->new
	}
	$lxs->do_query($self);
}

sub qstr_add { # PublicInbox::InputPipe::consume callback for --stdin
	my ($lei) = @_; # $_[1] = $rbuf
	$_[1] // $lei->fail("error reading stdin: $!");
	return $lei->{mset_opt}->{qstr} .= $_[1] if $_[1] ne '';
	eval {
		$lei->fchdir;
		$lei->{mset_opt}->{q_raw} = $lei->{mset_opt}->{qstr};
		$lei->{lse}->query_approxidate($lei->{lse}->git,
						$lei->{mset_opt}->{qstr});
		_start_query($lei);
	};
	$lei->fail($@) if $@;
}

sub lxs_prepare {
	my ($self) = @_;
	require PublicInbox::LeiXSearch;
	# prepare any number of LeiXSearch || LeiSearch || Inbox || URL
	my $lxs = $self->{lxs} = PublicInbox::LeiXSearch->new;
	my $opt = $self->{opt};
	my @only = @{$opt->{only} // []};
	# --local is enabled by default unless --only is used
	# we'll allow "--only $LOCATION --local"
	my $sto = $self->_lei_store(1);
	$self->{lse} = $sto->search;
	if ($opt->{'local'} //= scalar(@only) ? 0 : 1) {
		$lxs->prepare_external($self->{lse});
	}
	if (@only) {
		for my $loc (@only) {
			my @loc = $self->get_externals($loc) or return;
			$lxs->prepare_external($_) for @loc;
		}
	} else {
		my (@ilocals, @iremotes);
		for my $loc (@{$opt->{include} // []}) {
			my @loc = $self->get_externals($loc) or return;
			$lxs->prepare_external($_) for @loc;
			@ilocals = @{$lxs->{locals} // []};
			@iremotes = @{$lxs->{remotes} // []};
		}
		# --external is enabled by default, but allow --no-external
		if ($opt->{external} //= 1) {
			my $ex = $self->canonicalize_excludes($opt->{exclude});
			$self->externals_each(\&prep_ext, $lxs, $ex);
			$opt->{remote} //= !($lxs->locals - $opt->{'local'});
			$lxs->{locals} = \@ilocals if !$opt->{'local'};
			$lxs->{remotes} = \@iremotes if !$opt->{remote};
		}
	}
	($lxs->locals || $lxs->remotes) ? ($self->{lxs} = $lxs) :
		die("no local or remote inboxes to search\n");
}

# the main "lei q SEARCH_TERMS" method
sub lei_q {
	my ($self, @argv) = @_;
	PublicInbox::Config->json; # preload before forking
	my $lxs = lxs_prepare($self) or return;
	$self->ale->refresh_externals($lxs, $self);
	my $opt = $self->{opt};
	my %mset_opt;
	$mset_opt{asc} = $opt->{'reverse'} ? 1 : 0;
	if (defined(my $sort = $opt->{'sort'})) {
		if ($sort eq 'relevance') {
			$mset_opt{relevance} = 1;
		} elsif ($sort eq 'docid') {
			$mset_opt{relevance} = $mset_opt{asc} ? -1 : -2;
		} elsif ($sort =~ /\Areceived(?:-?[aA]t)?\z/) {
			# the default
		} else {
			die "unrecognized --sort=$sort\n";
		}
		$opt->{save} and return
			$self->fail('--save and --sort are incompatible');
	}
	$self->{mset_opt} = \%mset_opt;

	if ($opt->{stdin}) {
		return $self->fail(<<'') if @argv;
no query allowed on command-line with --stdin

		require PublicInbox::InputPipe;
		PublicInbox::InputPipe::consume($self->{0}, \&qstr_add, $self);
		return;
	}
	$mset_opt{q_raw} = [ @argv ]; # copy
	$mset_opt{qstr} =
		$self->{lse}->query_argv_to_string($self->{lse}->git, \@argv);
	_start_query($self);
}

# shell completion helper called by lei__complete
sub _complete_q {
	my ($self, @argv) = @_;
	my @cur;
	my $cb = $self->lazy_cb(qw(forget-external _complete_));
	while (@argv) {
		if ($argv[-1] =~ /\A(?:-I|(?:--(?:include|exclude|only)))\z/) {
			my @c = $cb->($self, @cur);
			# try basename match:
			if (scalar(@cur) == 1 && index($cur[0], '/') < 0) {
				my $all = $self->externals_each;
				my %bn;
				for my $loc (keys %$all) {
					my $bn = (split(m!/!, $loc))[-1];
					++$bn{$bn};
				}
				push @c, grep {
					$bn{$_} == 1 && /\A\Q$cur[0]/
				} keys %bn;
			}
			return @c if @c;
		}
		unshift(@cur, pop @argv);
	}
	();
}

# Stuff we may pass through to curl (as of 7.64.0), see curl manpage for
# details, so most options which make sense for HTTP/HTTPS (including proxy
# support for Tor and other methods of getting past weird networks).
# Most of these are untested by us, some may not make sense for our use case
# and typos below are likely.
# n.b. some short options (-$NUMBER) are not supported since they conflict
# with other "lei q" switches.
# FIXME: Getopt::Long doesn't easily let us support support options with
# '.' in them (e.g. --http1.1)
# TODO: should we depend on "-c http.*" options for things which have
# analogues in git(1)? that would reduce likelyhood of conflicts with
# our other CLI options
# Note: some names are renamed to avoid potential conflicts,
# see %lei2curl in lib/PublicInbox/LeiCurl.pm
sub curl_opt { qw(
	curl-config=s@
	abstract-unix-socket=s anyauth basic cacert=s capath=s
	cert-status cert-type cert=s ciphers=s
	connect-timeout=s connect-to=s cookie-jar=s cookie=s crlfile=s
	digest disable dns-interface=s dns-ipv4-addr=s dns-ipv6-addr=s
	dns-servers=s doh-url=s egd-file=s engine=s false-start
	happy-eyeballs-timeout-ms=s haproxy-protocol header=s@
	http2-prior-knowledge http2 insecure
	interface=s ipv4 ipv6 junk-session-cookies
	key-type=s key=s limit-rate=s local-port=s location-trusted location
	max-redirs=i max-time=s negotiate netrc-file=s netrc-optional netrc
	no-alpn no-buffer no-npn no-sessionid noproxy=s ntlm-wb ntlm
	pass=s pinnedpubkey=s post301 post302 post303 preproxy=s
	proxy-anyauth proxy-basic proxy-cacert=s proxy-capath=s
	proxy-cert-type=s proxy-cert=s proxy-ciphers=s proxy-crlfile=s
	proxy-digest proxy-header=s@ proxy-insecure
	proxy-key-type=s proxy-key proxy-negotiate proxy-ntlm proxy-pass=s
	proxy-pinnedpubkey=s proxy-service-name=s proxy-ssl-allow-beast
	proxy-tls13-ciphers=s proxy-tlsauthtype=s proxy-tlspassword=s
	proxy-tlsuser=s proxy-tlsv1 proxy-user=s proxy=s
	proxytunnel=s pubkey=s random-file=s referer=s resolve=s
	retry-connrefused retry-delay=s retry-max-time=s retry=i
	sasl-ir service-name=s socks4=s socks4a=s socks5-basic
	socks5-gssapi-service-name=s socks5-gssapi socks5-hostname=s socks5=s
	speed-limit speed-type ssl-allow-beast sslv2 sslv3
	suppress-connect-headers tcp-fastopen tls-max=s
	tls13-ciphers=s tlsauthtype=s tlspassword=s tlsuser=s
	tlsv1 trace-ascii=s trace-time trace=s
	unix-socket=s user-agent=s user=s
)
}

1;
