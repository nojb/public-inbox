# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Maildirs for now, MH eventually
# ref: https://cr.yp.to/proto/maildir.html
#	https://wiki2.dovecot.org/MailboxFormat/Maildir
package PublicInbox::MdirReader;
use strict;
use v5.10.1;

# returns Maildir flags from a basename ('' for no flags, undef for invalid)
sub maildir_basename_flags {
	my (@f) = split(/:/, $_[0], -1);
	return if (scalar(@f) > 2 || substr($f[0], 0, 1) eq '.');
	$f[1] // return ''; # "new"
	$f[1] =~ /\A2,([A-Za-z]*)\z/ ? $1 : undef; # "cur"
}

# same as above, but for full path name
sub maildir_path_flags {
	my ($f) = @_;
	my $i = rindex($f, '/');
	$i >= 0 ? maildir_basename_flags(substr($f, $i + 1)) : undef;
}

sub maildir_each_file ($$;@) {
	my ($dir, $cb, @arg) = @_;
	$dir .= '/' unless substr($dir, -1) eq '/';
	for my $d (qw(new/ cur/)) {
		my $pfx = $dir.$d;
		opendir my $dh, $pfx or next;
		while (defined(my $bn = readdir($dh))) {
			maildir_basename_flags($bn) // next;
			$cb->($pfx.$bn, @arg);
		}
	}
}

1;
