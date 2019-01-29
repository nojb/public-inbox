# Copyright (C) 2015-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Various Message-ID-related functions.
package PublicInbox::MID;
use strict;
use warnings;
use base qw/Exporter/;
our @EXPORT_OK = qw/mid_clean id_compress mid2path mid_mime mid_escape MID_ESC
	mids references/;
use URI::Escape qw(uri_escape_utf8);
use Digest::SHA qw/sha1_hex/;
require PublicInbox::Address;
use constant {
	MID_MAX => 40, # SHA-1 hex length # TODO: get rid of this
	MAX_MID_SIZE => 244, # max term size (Xapian limitation) - length('Q')
};

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

# Only for v1 code paths:
sub mid_mime ($) { mids($_[0]->header_obj)->[0] }

sub mids ($) {
	my ($hdr) = @_;
	my @mids;
	my @v = $hdr->header_raw('Message-Id');
	foreach my $v (@v) {
		my @cur = ($v =~ /<([^>]+)>/sg);
		if (@cur) {
			push(@mids, @cur);
		} else {
			push(@mids, $v);
		}
	}
	uniq_mids(\@mids);
}

# last References should be IRT, but some mail clients do things
# out of order, so trust IRT over References iff IRT exists
sub references ($) {
	my ($hdr) = @_;
	my @mids;
	foreach my $f (qw(References In-Reply-To)) {
		my @v = $hdr->header_raw($f);
		foreach my $v (@v) {
			push(@mids, ($v =~ /<([^>]+)>/sg));
		}
	}

	# old versions of git-send-email would prompt users for
	# In-Reply-To and users' muscle memory would use 'y' or 'n'
	# as responses:
	my %addr = ( y => 1, n => 1 );

	foreach my $f (qw(To From Cc)) {
		my @v = $hdr->header_raw($f);
		foreach my $v (@v) {
			$addr{$_} = 1 for (PublicInbox::Address::emails($v));
		}
	}
	uniq_mids(\@mids, \%addr);
}

sub uniq_mids ($;$) {
	my ($mids, $seen) = @_;
	my @ret;
	$seen ||= {};
	foreach my $mid (@$mids) {
		$mid =~ tr/\n\t\r//d;
		if (length($mid) > MAX_MID_SIZE) {
			warn "Message-ID: <$mid> too long, truncating\n";
			$mid = substr($mid, 0, MAX_MID_SIZE);
		}
		next if $seen->{$mid};
		push @ret, $mid;
		$seen->{$mid} = 1;
	}
	\@ret;
}

# RFC3986, section 3.3:
sub MID_ESC () { '^A-Za-z0-9\-\._~!\$\&\';\(\)\*\+,;=:@' }
sub mid_escape ($) { uri_escape_utf8($_[0], MID_ESC) }

1;
