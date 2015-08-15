# Copyright (C) 2015, all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
package PublicInbox::MID;
use strict;
use warnings;
use base qw/Exporter/;
our @EXPORT_OK = qw/mid_clean mid_compressed/;
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
sub mid_compressed {
	my ($mid) = @_;
	return $mid if (length($mid) <= MID_MAX);
	sha1_hex($mid);
}

1;
