# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# callers should use PublicInbox::CmdIPC4->can('send_cmd4') (or recv_cmd4)
# first choice for script/lei front-end and 2nd choice for lei backend
# libsocket-msghdr-perl is in Debian but many other distros as of 2021.
package PublicInbox::CmdIPC4;
use strict;
use v5.10.1;
use Socket qw(SOL_SOCKET SCM_RIGHTS);
BEGIN { eval {
require Socket::MsgHdr; # XS
no warnings 'once';

# 3 FDs per-sendmsg(2) + buffer
*send_cmd4 = sub ($$$$) { # (sock, fds, buf, flags) = @_;
	my ($sock, $fds, undef, $flags) = @_;
	my $mh = Socket::MsgHdr->new(buf => $_[2]);
	$mh->cmsghdr(SOL_SOCKET, SCM_RIGHTS,
			pack('i' x scalar(@$fds), @$fds));
	Socket::MsgHdr::sendmsg($sock, $mh, $flags) or die "sendmsg: $!";
};

*recv_cmd4 = sub ($$$) {
	my ($s, undef, $len) = @_; # $_[1] = destination buffer
	my $mh = Socket::MsgHdr->new(buflen => $len, controllen => 256);
	my $r = Socket::MsgHdr::recvmsg($s, $mh, 0) // die "recvmsg: $!";
	$_[1] = $mh->buf;
	return () if $r == 0;
	my (undef, undef, $data) = $mh->cmsghdr;
	unpack('i' x (length($data) / 4), $data);
};

} } # /eval /BEGIN

1;
