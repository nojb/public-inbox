# Copyright (C) 2015-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Various Message-ID-related functions.
package PublicInbox::MID;
use strict;
use warnings;
use base qw/Exporter/;
our @EXPORT_OK = qw/mid_clean id_compress mid2path mid_mime mid_escape MID_ESC/;
use URI::Escape qw(uri_escape_utf8);
use Digest::SHA qw/sha1_hex/;
use constant MID_MAX => 40; # SHA-1 hex length

sub mid_clean {
	my ($mid) = @_;
	defined($mid) or die "no Message-ID";
	# MDA->precheck did more checking for us
	if ($mid =~ /<([^>]+)>/) {
		$mid = $1;
	}
	$mid;
}

# this is idempotent
sub id_compress {
	my ($id, $force) = @_;

	if ($force || $id =~ /[^\w\-]/ || length($id) > MID_MAX) {
		utf8::encode($id);
		return sha1_hex($id);
	}
	$id;
}

sub mid2path {
	my ($mid) = @_;
	my ($x2, $x38) = ($mid =~ /\A([a-f0-9]{2})([a-f0-9]{38})\z/);

	unless (defined $x38) {
		# compatibility with old links (or short Message-IDs :)
		$mid = mid_clean($mid);
		utf8::encode($mid);
		$mid = sha1_hex($mid);
		($x2, $x38) = ($mid =~ /\A([a-f0-9]{2})([a-f0-9]{38})\z/);
	}
	"$x2/$x38";
}

sub mid_mime ($) { $_[0]->header_obj->header_raw('Message-ID') }

# RFC3986, section 3.3:
sub MID_ESC () { '^A-Za-z0-9\-\._~!\$\&\';\(\)\*\+,;=:@' }
sub mid_escape ($) { uri_escape_utf8($_[0], MID_ESC) }

1;
