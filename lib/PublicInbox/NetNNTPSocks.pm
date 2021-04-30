# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# wrap Net::NNTP client with SOCKS support
package PublicInbox::NetNNTPSocks;
use strict;
use v5.10.1;
use Net::NNTP;
our %OPT;
our @ISA = qw(IO::Socket::Socks);
my @SOCKS_KEYS = qw(ProxyAddr ProxyPort SocksVersion SocksDebug SocksResolve);

# use this instead of Net::NNTP->new if using Proxy*
sub new_socks {
	my (undef, %opt) = @_;
	require IO::Socket::Socks;
	local @Net::NNTP::ISA = (qw(Net::Cmd), __PACKAGE__);
	local %OPT = map {;
		defined($opt{$_}) ? ($_ => $opt{$_}) : ()
	} @SOCKS_KEYS;
	Net::NNTP->new(%opt); # this calls our new() below:
}

# called by Net::NNTP->new
sub new {
	my ($self, %opt) = @_;
	@OPT{qw(ConnectAddr ConnectPort)} = @opt{qw(PeerAddr PeerPort)};
	my $ret = $self->SUPER::new(%OPT) or
		die 'SOCKS error: '.eval('$IO::Socket::Socks::SOCKS_ERROR');
	$ret;
}

1;
