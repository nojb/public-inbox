# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# connects public-inbox processes to public-inbox-gcf2(1)
package PublicInbox::Gcf2Client;
use strict;
use parent 'PublicInbox::Git';
use PublicInbox::Spawn qw(popen_rd);
use IO::Handle ();

sub new {
	my ($rdr) = @_;
	my $self = bless {}, __PACKAGE__;
	my ($out_r, $out_w);
	pipe($out_r, $out_w) or $self->fail("pipe failed: $!");
	$rdr //= {};
	$rdr->{0} = $out_r;
	@$self{qw(in pid)} = popen_rd(['public-inbox-gcf2'], undef, $rdr);
	$self->{inflight} = [];
	$self->{out} = $out_w;
	fcntl($out_w, 1031, 4096) if $^O eq 'linux'; # 1031: F_SETPIPE_SZ
	$out_w->autoflush(1);
	$self;
}

# always false, since -gcf2 retries internally
sub alternates_changed {}

1;
