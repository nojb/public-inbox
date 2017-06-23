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

sub add_addrs {
	my ($to, $cc, @addrs) = @_;
	foreach my $address (@addrs) {
		my $dst = lc($address);
		$cc->{$dst} ||= $address;
		$$to ||= $dst;
	}
}

my @reply_headers = qw(From To Cc Reply-To);
my $reply_headers = join('|', @reply_headers);

sub mailto_arg_link {
	my ($ibx, $hdr) = @_;
	my $cc = {}; # everyone else
	my $to; # this is the From address by default

	foreach my $rt (split(/\s*,\s*/, $ibx->{replyto} || ':all')) {
		if ($rt eq ':all') {
			foreach my $h (@reply_headers) {
				my $v = $hdr->header($h);
				defined($v) && ($v ne '') or next;
				my @addrs = PublicInbox::Address::emails($v);
				add_addrs(\$to, $cc, @addrs);
			}
		} elsif ($rt eq ':list') {
			add_addrs(\$to, $cc, $ibx->{-primary_address});
		} elsif ($rt =~ /\A(?:$reply_headers)\z/io) {
			my $v = $hdr->header($rt);
			if (defined($v) && ($v ne '')) {
				my @addrs = PublicInbox::Address::emails($v);
				add_addrs(\$to, $cc, @addrs);
			}
		} elsif ($rt =~ /@/) {
			add_addrs(\$to, $cc, $rt);
		} else {
			warn "Unrecognized replyto = '$rt' in config\n";
		}
	}

	my @arg;
	my $obfs = $ibx->{obfuscate};
	my $subj = $hdr->header('Subject') || '';
	$subj = "Re: $subj" unless $subj =~ /\bRe:/i;
	my $mid = $hdr->header_raw('Message-ID');
	push @arg, '--in-reply-to='.squote_maybe(mid_clean($mid));
	my $irt = mid_escape($mid);
	delete $cc->{$to};
	if ($obfs) {
		my $arg_to = $to;
		$arg_to =~ s/\./\$(echo .)/;
		push @arg, "--to=$arg_to";
	} else {
		push @arg, "--to=$to";
		$to = uri_escape_utf8($to);
		$subj = uri_escape_utf8($subj);
	}
	my @cc = sort values %$cc;
	$cc = '';
	if (@cc) {
		if ($obfs) {
			push(@arg, map {
				s/\./\$(echo .)/;
				"--cc=$_";
			} @cc);
		} else {
			$cc = '&Cc=' . uri_escape_utf8(join(',', @cc));
			push(@arg, map { "--cc=$_" } @cc);
		}
	}

	# I'm not sure if address obfuscation and mailto: links can
	# be made compatible; and address obfuscation is misguided,
	# anyways.
	return (\@arg, '') if $obfs;

	# order matters, Subject is the least important header,
	# so it is last in case it's lost/truncated in a copy+paste
	my $href = "mailto:$to?In-Reply-To=$irt${cc}&Subject=$subj";

	(\@arg, ascii_html($href));
}

1;
