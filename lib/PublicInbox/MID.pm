# Copyright (C) 2015, all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
package PublicInbox::MID;
use strict;
use warnings;
use base qw/Exporter/;
our @EXPORT_OK = qw/mid_clean mid_compress mid2path/;
use Digest::SHA qw/sha1_hex/;
use constant MID_MAX => 40; # SHA-1 hex length

sub mid_clean {
	my ($mid) = @_;
	defined($mid) or die "no Message-ID";
	# MDA->precheck did more checking for us
	$mid =~ s/\A\s*<?//;
	$mid =~ s/>?\s*\z//;
	$mid;
}

# this is idempotent
sub mid_compress {
	my ($mid, $force) = @_;

	# XXX dirty hack! FIXME!
	# Some HTTP servers (apache2 2.2.22-13+deb7u5 on my system)
	# apparently do not handle "%25" in the URL path component correctly.
	# I'm not yet sure if it's something weird with my rewrite rules
	# or what; will need to debug...
	return sha1_hex($mid) if (index($mid, '%') >= 0);

	return $mid if (!$force && length($mid) <= MID_MAX);
	sha1_hex($mid);
}

sub mid2path {
	my ($mid) = @_;
	my ($x2, $x38) = ($mid =~ /\A([a-f0-9]{2})([a-f0-9]{38})\z/);

	unless (defined $x38) {
		# compatibility with old links (or short Message-IDs :)
		$mid = sha1_hex($mid);
		($x2, $x38) = ($mid =~ /\A([a-f0-9]{2})([a-f0-9]{38})\z/);
	}
	"$x2/$x38";
}

1;
