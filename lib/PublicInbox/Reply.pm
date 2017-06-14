# Copyright (C) 2014-2017 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
package PublicInbox::Reply;
use strict;
use warnings;
use URI::Escape qw/uri_escape_utf8/;
use PublicInbox::Hval qw/ascii_html/;
use PublicInbox::Address;
use PublicInbox::MID qw/mid_clean mid_escape/;

sub squote_maybe ($) {
	my ($val) = @_;
	if ($val =~ m{([^\w@\./,\%\+\-])}) {
		$val =~ s/(['!])/'\\$1'/g; # '!' for csh
		return "'$val'";
	}
	$val;
}

sub mailto_arg_link {
	my ($hdr) = @_;
	my %cc; # everyone else
	my $to; # this is the From address

	foreach my $h (qw(From To Cc)) {
		my $v = $hdr->header($h);
		defined($v) && ($v ne '') or next;
		my @addrs = PublicInbox::Address::emails($v);
		foreach my $address (@addrs) {
			my $dst = lc($address);
			$cc{$dst} ||= $address;
			$to ||= $dst;
		}
	}
	my @arg;

	my $subj = $hdr->header('Subject') || '';
	$subj = "Re: $subj" unless $subj =~ /\bRe:/i;
	my $mid = $hdr->header_raw('Message-ID');
	push @arg, '--in-reply-to='.squote_maybe(mid_clean($mid));
	my $irt = mid_escape($mid);
	delete $cc{$to};
	push @arg, "--to=$to";
	$to = uri_escape_utf8($to);
	$subj = uri_escape_utf8($subj);
	my @cc = sort values %cc;
	push(@arg, map { "--cc=$_" } @cc);
	my $cc = uri_escape_utf8(join(',', @cc));
	my $href = "mailto:$to?In-Reply-To=$irt&Cc=${cc}&Subject=$subj";

	(\@arg, ascii_html($href));
}

1;
