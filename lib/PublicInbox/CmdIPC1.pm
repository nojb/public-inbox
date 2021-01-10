# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# callers should use PublicInbox::CmdIPC1->can('send_cmd1') (or recv_cmd1)
# 2nd choice for lei(1) front-end and 3rd choice for lei internals
package PublicInbox::CmdIPC1;
use strict;
use v5.10.1;
BEGIN { eval {
require IO::FDPass; # XS, available in all major distros
no warnings 'once';

*send_cmd1 = sub ($$$$) { # (sock, fds, buf, flags) = @_;
	my ($sock, $fds, undef, $flags) = @_;
	for my $fd (@$fds) {
		IO::FDPass::send(fileno($sock), $fd) or
					die "IO::FDPass::send: $!";
	}
	send($sock, $_[2], $flags) or die "send $!";
};

*recv_cmd1 = sub ($$$;$) {
	my ($s, undef, $len, $nfds) = @_;
	$nfds //= 3;
	my @fds = map { IO::FDPass::recv(fileno($s)) } (1..$nfds);
	recv($s, $_[1], $len, 0) // die "recv: $!";
	length($_[1]) == 0 ? () : @fds;
};

} } # /eval /BEGIN

1;
