# Copyright (C) 2018-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Unstable internal API.
# Used for on-the-fly duplicate detection in V2 inboxes.
# This is not stored in any database anywhere and may change
# as changes in duplicate detection are needed.
# See L<public-inbox-v2-format(5)> manpage for more details.
package PublicInbox::ContentHash;
use strict;
use v5.10.1;
use parent qw(Exporter);
our @EXPORT_OK = qw(content_hash content_digest git_sha);
use PublicInbox::MID qw(mids references);
use PublicInbox::MsgIter;

# not sure if less-widely supported hash families are worth bothering with
use Digest::SHA;

sub digest_addr ($$$) {
	my ($dig, $h, $v) = @_;
	$v =~ tr/"//d;
	$v =~ s/@([a-z0-9\_\.\-\(\)]*([A-Z])\S*)/'@'.lc($1)/ge;
	utf8::encode($v);
	$dig->add("$h\0$v\0");
}

sub content_dig_i {
	my ($dig) = $_[1];
	my ($part, $depth, @idx) = @{$_[0]};
	$dig->add("\0$depth:".join('.', @idx)."\0");
	my $fn = $part->filename;
	if (defined $fn) {
		utf8::encode($fn);
		$dig->add("fn\0$fn\0");
	}
	my @d = $part->header('Content-Description');
	foreach my $d (@d) {
		utf8::encode($d);
		$dig->add("d\0$d\0");
	}
	$dig->add("b\0");
	my $ct = $part->content_type || 'text/plain';
	my ($s, undef) = msg_part_text($part, $ct);
	if (defined $s) {
		$s =~ s/\r\n/\n/gs;
		$s =~ s/\s*\z//s;
		utf8::encode($s);
	} else {
		$s = $part->body;
	}
	$dig->add($s);
}

sub content_digest ($;$) {
	my ($eml, $dig) = @_;
	$dig //= Digest::SHA->new(256);

	# References: and In-Reply-To: get used interchangeably
	# in some "duplicates" in LKML.  We treat them the same
	# in SearchIdx, so treat them the same for this:
	# do NOT consider the Message-ID as part of the content_hash
	# if we got here, we've already got Message-ID reuse
	my %seen = map { $_ => 1 } @{mids($eml)};
	foreach my $mid (@{references($eml)}) {
		$dig->add("ref\0$mid\0") unless $seen{$mid}++;
	}

	# Only use Sender: if From is not present
	foreach my $h (qw(From Sender)) {
		my @v = $eml->header($h) or next;
		digest_addr($dig, $h, $_) foreach @v;
		last;
	}
	foreach my $h (qw(Subject Date)) {
		my @v = $eml->header($h);
		foreach my $v (@v) {
			utf8::encode($v);
			$dig->add("$h\0$v\0");
		}
	}
	# Some mail processors will add " to unquoted names that were
	# not in the original message.  For the purposes of deduplication,
	# do not take it into account:
	foreach my $h (qw(To Cc)) {
		my @v = $eml->header($h);
		digest_addr($dig, $h, $_) foreach @v;
	}
	msg_iter($eml, \&content_dig_i, $dig);
	$dig;
}

sub content_hash ($) {
	content_digest($_[0])->digest;
}

sub git_sha ($$) {
	my ($n, $eml) = @_;
	my $dig = Digest::SHA->new($n);
	my $bref = ref($eml) eq 'SCALAR' ? $eml : \($eml->as_string);
	$dig->add('blob '.length($$bref)."\0");
	$dig->add($$bref);
	$dig;
}

1;
