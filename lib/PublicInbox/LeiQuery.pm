# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# handles lei <q|ls-query|rm-query|mv-query> commands
package PublicInbox::LeiQuery;
use strict;
use v5.10.1;
use PublicInbox::DS qw(dwaitpid);

sub prep_ext { # externals_each callback
	my ($lxs, $exclude, $loc) = @_;
	$lxs->prepare_external($loc) unless $exclude->{$loc};
}

# the main "lei q SEARCH_TERMS" method
sub lei_q {
	my ($self, @argv) = @_;
	require PublicInbox::LeiXSearch;
	require PublicInbox::LeiOverview;
	PublicInbox::Config->json; # preload before forking
	my $opt = $self->{opt};
	# prepare any number of LeiXSearch || LeiSearch || Inbox || URL
	my $lxs = $self->{lxs} = PublicInbox::LeiXSearch->new;
	my @only = @{$opt->{only} // []};
	# --local is enabled by default unless --only is used
	# we'll allow "--only $LOCATION --local"
	if ($opt->{'local'} //= scalar(@only) ? 0 : 1) {
		my $sto = $self->_lei_store(1);
		$lxs->prepare_external($sto->search);
	}
	if (@only) {
		for my $loc (@only) {
			$lxs->prepare_external($self->ext_canonicalize($loc));
		}
	} else {
		for my $loc (@{$opt->{include} // []}) {
			$lxs->prepare_external($self->ext_canonicalize($loc));
		}
		# --external is enabled by default, but allow --no-external
		if ($opt->{external} //= 1) {
			my %x = map {;
				($self->ext_canonicalize($_), 1)
			} @{$self->{exclude} // []};
			my $ne = $self->externals_each(\&prep_ext, $lxs, \%x);
			$opt->{remote} //= !($lxs->locals - $opt->{'local'});
			if ($opt->{'local'}) {
				delete($lxs->{remotes}) if !$opt->{remote};
			} else {
				delete($lxs->{locals});
			}
		}
	}
	unless ($lxs->locals || $lxs->remotes) {
		return $self->fail('no local or remote inboxes to search');
	}
	my $xj = $lxs->concurrency($opt);
	my $ovv = PublicInbox::LeiOverview->new($self) or return;
	$self->atfork_prepare_wq($lxs);
	$lxs->wq_workers_start('lei_xsearch', $xj, $self->oldset);
	delete $lxs->{-ipc_atfork_child_close};
	if (my $l2m = $self->{l2m}) {
		my $mj = 4; # TODO: configurable
		$self->atfork_prepare_wq($l2m);
		$l2m->wq_workers_start('lei2mail', $mj, $self->oldset);
		delete $l2m->{-ipc_atfork_child_close};
	}

	# no forking workers after this

	my %mset_opt = map { $_ => $opt->{$_} } qw(thread limit offset);
	$mset_opt{asc} = $opt->{'reverse'} ? 1 : 0;
	$mset_opt{limit} //= 10000;
	$mset_opt{qstr} = join(' ', map {;
		# Consider spaces in argv to be for phrase search in Xapian.
		# In other words, the users should need only care about
		# normal shell quotes and not have to learn Xapian quoting.
		/\s/ ? (s/\A(\w+:)// ? qq{$1"$_"} : qq{"$_"}) : $_
	} @argv);
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
	}
	# descending docid order
	$mset_opt{relevance} //= -2 if $opt->{thread};
	$self->{mset_opt} = \%mset_opt;
	$ovv->ovv_begin($self);
	$lxs->do_query($self);
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
sub curl_opt { qw(
	abstract-unix-socket=s anyauth basic cacert=s capath=s
	cert-status cert-type cert|E=s ciphers=s config|K=s@
	connect-timeout=s connect-to=s cookie-jar|c=s cookie|b=s crlfile=s
	digest disable dns-interface=s dns-ipv4-addr=s dns-ipv6-addr=s
	dns-servers=s doh-url=s egd-file=s engine=s false-start
	happy-eyeballs-timeout-ms=s haproxy-protocol header|H=s@
	http2-prior-knowledge http2 insecure|k
	interface=s ipv4 ipv6 junk-session-cookies
	key-type=s key=s limit-rate=s local-port=s location-trusted location|L
	max-redirs=i max-time=s negotiate netrc-file=s netrc-optional netrc
	no-alpn no-buffer|N no-npn no-sessionid noproxy=s ntlm-wb ntlm
	pass=s pinnedpubkey=s post301 post302 post303 preproxy=s
	proxy-anyauth proxy-basic proxy-cacert=s proxy-capath=s
	proxy-cert-type=s proxy-cert=s proxy-ciphers=s proxy-crlfile=s
	proxy-digest proxy-header=s@ proxy-insecure
	proxy-key-type=s proxy-key proxy-negotiate proxy-ntlm proxy-pass=s
	proxy-pinnedpubkey=s proxy-service-name=s proxy-ssl-allow-beast
	proxy-tls13-ciphers=s proxy-tlsauthtype=s proxy-tlspassword=s
	proxy-tlsuser=s proxy-tlsv1 proxy-user|U=s proxy=s
	proxytunnel=s pubkey=s random-file=s referer=s resolve=s
	retry-connrefused retry-delay=s retry-max-time=s retry=i
	sasl-ir service-name=s socks4=s socks4a=s socks5-basic
	socks5-gssapi-service-name=s socks5-gssapi socks5-hostname=s socks5=s
	speed-limit|Y speed-type|y ssl-allow-beast sslv2 sslv3
	suppress-connect-headers tcp-fastopen tls-max=s
	tls13-ciphers=s tlsauthtype=s tlspassword=s tlsuser=s
	tlsv1 trace-ascii=s trace-time trace=s
	unix-socket=s user-agent|A=s user|u=s
)
}

1;
