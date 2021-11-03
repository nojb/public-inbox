# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# common option and torsocks(1) wrapping for curl(1)
# Eventually, we may support using libcurl via Inline::C and/or
# WWW::Curl; but curl(1) is most prevalent and widely-installed.
# n.b. curl may support a daemon/client model like lei someday:
#   https://github.com/curl/curl/wiki/curl-tool-master-client
package PublicInbox::LeiCurl;
use strict;
use v5.10.1;
use PublicInbox::Spawn qw(which);
use PublicInbox::Config;

# Ensures empty strings are quoted, we don't need more
# sophisticated quoting than for empty strings: curl -d ''
use overload '""' => sub {
	join(' ', map { $_ eq '' ?  "''" : $_ } @{$_[0]});
};

my %lei2curl = (
	'curl-config=s@' => 'config|K=s@',
);

# prepares a common command for curl(1) based on $lei command
sub new {
	my ($cls, $lei, $curl) = @_;
	$curl //= which('curl') // return $lei->fail('curl not found');
	my $opt = $lei->{opt};
	my @cmd = ($curl, qw(-Sf));
	$cmd[-1] .= 's' if $opt->{quiet}; # already the default for "lei q"
	$cmd[-1] .= 'v' if $opt->{verbose}; # we use ourselves, too
	for my $o ($lei->curl_opt) {
		if (my $lei_spec = $lei2curl{$o}) {
			$o = $lei_spec;
		}
		$o =~ s/\|[a-z0-9]\b//i; # remove single char short option
		if ($o =~ s/=[is]@\z//) {
			my $ary = $opt->{$o} or next;
			push @cmd, map { ("--$o", $_) } @$ary;
		} elsif ($o =~ s/=[is]\z//) {
			my $val = $opt->{$o} // next;
			push @cmd, "--$o", $val;
		} elsif ($opt->{$o}) {
			push @cmd, "--$o";
		}
	}
	push @cmd, '-v' if $opt->{verbose}; # lei uses this itself
	bless \@cmd, $cls;
}

sub torsocks { # useful for "git clone" and "git fetch", too
	my ($self, $lei, $uri)= @_;
	my $opt = $lei->{opt};
	$opt->{torsocks} = 'false' if $opt->{'no-torsocks'};
	my $torsocks = $opt->{torsocks} //= 'auto';
	if ($torsocks eq 'auto' && substr($uri->host, -6) eq '.onion' &&
		($PublicInbox::Config::LD_PRELOAD//'') !~ m!/libtorsocks\b!) {
		# "auto" continues anyways if torsocks is missing;
		# a proxy may be specified via CLI, curlrc,
		# environment variable, or even firewall rule
		[ ($lei->{torsocks} //= which('torsocks')) // () ]
	} elsif (PublicInbox::Config::git_bool($torsocks)) {
		my $x = $lei->{torsocks} //= which('torsocks');
		$x or return $lei->fail(<<EOM);
--torsocks=yes specified but torsocks not found in PATH=$ENV{PATH}
EOM
		[ $x ];
	} else { # the common case for current Internet :<
		[];
	}
}

# completes the result of cmd() for $uri
sub for_uri {
	my ($self, $lei, $uri, @opt) = @_;
	my $pfx = torsocks($self, $lei, $uri) or return; # error
	if ($uri->scheme =~ /\Ahttps?\z/i) {
		my $cfg = $lei->_lei_cfg;
		my $p = $cfg ? $cfg->urlmatch('http.Proxy', $$uri) : undef;
		push(@opt, "--proxy=$p") if defined($p);
	}
	bless [ @$pfx, @$self, @opt, $uri->as_string ], ref($self);
}

1;
