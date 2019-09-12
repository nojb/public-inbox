# Copyright (C) 2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
package PublicInbox::Tmpfile;
use strict;
use warnings;
use base qw(Exporter);
our @EXPORT = qw(tmpfile);
use Fcntl qw(:DEFAULT);
use Errno qw(EEXIST);
require File::Spec;

# use tmpfile instead of open(..., '+>', undef) so we can get an
# unlinked filename which makes sense when viewed with lsof
# (at least on Linux)
# And if we ever stop caring to have debuggable filenames, O_TMPFILE :)
sub tmpfile ($;$$) {
	my ($id, $sock, $append) = @_;
	if (defined $sock) {
		# add the socket inode number so we can figure out which
		# socket it belongs to
		my @st = stat($sock);
		$id .= '-ino:'.$st[1];
	}
	$id =~ tr!/!^!;

	my $fl = O_RDWR | O_CREAT | O_EXCL;
	$fl |= O_APPEND if $append;
	do {
		my $fn = File::Spec->tmpdir . "/$id-".time.'-'.rand;
		if (sysopen(my $fh, $fn, $fl, 0600)) { # likely
			unlink($fn) or warn "unlink($fn): $!"; # FS broken
			return $fh; # success
		}
	} while ($! == EEXIST);
	undef  # EMFILE/ENFILE/ENOSPC/ENOMEM
}

1;
