# Copyright (C) 2015-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Various Message-ID-related functions.
package PublicInbox::MID;
use strict;
use warnings;
use base qw/Exporter/;
our @EXPORT_OK = qw(mid_clean id_compress mid2path mid_escape MID_ESC
	mids references mids_for_index $MID_EXTRACT);
use URI::Escape qw(uri_escape_utf8);
use Digest::SHA qw/sha1_hex/;
require PublicInbox::Address;
use constant {
	MID_MAX => 40, # SHA-1 hex length # TODO: get rid of this
	MAX_MID_SIZE => 244, # max term size (Xapian limitation) - length('Q')
};

our $MID_EXTRACT = qr/<([^>]+)>/s;

sub mid_clean {
	my ($mid) = @_;
	defined($mid) or die "no Message-ID";
	# MDA->precheck did more checking for us
	if ($mid =~ $MID_EXTRACT) {
		$mid = $1;
	}
	$mid;
}

# this is idempotent, used for HTML anchor/ids and such
sub id_compress {
	my ($id, $force) = @_;

	if ($force || $id =~ /[^a-zA-Z0-9_\-]/ || length($id) > MID_MAX) {
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

# only intended for Message-ID and X-Alt-Message-ID
sub extract_mids {
	my @mids;
	for my $v (@_) {
		my @cur = ($v =~ /$MID_EXTRACT/g);
		if (@cur) {
			push(@mids, @cur);
		} else {
			push(@mids, $v);
		}
	}
	\@mids;
}

sub mids ($) {
	my ($hdr) = @_;
	my @mids = $hdr->header_raw('Message-ID');
	uniq_mids(extract_mids(@mids));
}

# we allow searching on X-Alt-Message-ID since PublicInbox::NNTP uses them
# to placate some clients, and we want to ensure NNTP-only clients can
# import and index without relying on HTTP endpoints
sub mids_for_index ($) {
	my ($hdr) = @_;
	my @mids = $hdr->header_raw('Message-ID');
	my @alts = $hdr->header_raw('X-Alt-Message-ID');
	uniq_mids(extract_mids(@mids, @alts));
}

# last References should be IRT, but some mail clients do things
# out of order, so trust IRT over References iff IRT exists
sub references ($) {
	my ($hdr) = @_;
	my @mids;
	foreach my $f (qw(References In-Reply-To)) {
		my @v = $hdr->header_raw($f);
		foreach my $v (@v) {
			push(@mids, ($v =~ /$MID_EXTRACT/g));
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
		push(@ret, $mid) unless $seen->{$mid}++;
	}
	\@ret;
}

# RFC3986, section 3.3:
sub MID_ESC () { '^A-Za-z0-9\-\._~!\$\&\';\(\)\*\+,;=:@' }
sub mid_escape ($) { uri_escape_utf8($_[0], MID_ESC) }

1;
