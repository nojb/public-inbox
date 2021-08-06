# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Wrapper for Linux::Inotify2 < 2.3 which lacked ->fh and auto-close
# Remove this when supported LTS/enterprise distros are all
# Linux::Inotify2 >= 2.3
package PublicInbox::LI2Wrap;
use v5.10.1;
our @ISA = qw(Linux::Inotify2);

sub wrapclose {
	my ($inot) = @_;
	my $fd = $inot->fileno;
	open my $fh, '<&=', $fd or die "open <&= $fd $!";
	bless $inot, __PACKAGE__;
}

sub DESTROY {} # no-op

1
