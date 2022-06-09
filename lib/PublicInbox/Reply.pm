# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# For reply instructions and address generation in WWW UI
package PublicInbox::Reply;
use strict;
use v5.10.1;
use URI::Escape qw/uri_escape_utf8/;
use PublicInbox::Hval qw(ascii_html obfuscate_addrs mid_href);
use PublicInbox::Address;
use PublicInbox::MID qw(mid_clean);
use PublicInbox::Config;

*squote_maybe = \&PublicInbox::Config::squote_maybe;

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
	my $reply_to_all = 'reply-to-all'; # the only good default :P
	my $reply_to_cfg = $ibx->{replyto};

	$reply_to_cfg ||= ':all';
	if ($reply_to_cfg =~ /\A:none=(.*)/) {
		my $msg = $1;
		$msg = 'replies disabled' if $msg eq '';
		return \$msg;
	}

	foreach my $rt (split(/\s*,\s*/, $reply_to_cfg)) {
		if ($rt eq ':all') {
			foreach my $h (@reply_headers) {
				my $v = $hdr->header($h);
				defined($v) && ($v ne '') or next;
				my @addrs = PublicInbox::Address::emails($v);
				add_addrs(\$to, $cc, @addrs);
			}
		} elsif ($rt eq ':list') {
			$reply_to_all = 'reply-to-list';
			add_addrs(\$to, $cc, $ibx->{-primary_address});
		} elsif ($rt =~ /\A(?:$reply_headers)\z/io) {
			# ugh, this is weird...
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
	my $subj_raw = $subj;
	my $mid = $hdr->header_raw('Message-ID');
	push @arg, '--in-reply-to='.squote_maybe(mid_clean($mid));
	my $irt = mid_href($mid);
	add_addrs(\$to, $cc, $ibx->{-primary_address}) unless defined($to);
	delete $cc->{$to};
	if ($obfs) {
		my $arg_to = $to;
		obfuscate_addrs($ibx, $arg_to, '$(echo .)');
		push @arg, "--to=$arg_to";
		# no $subj for $href below
	} else {
		push @arg, "--to=$to";
		$subj = uri_escape_utf8($subj);
	}
	my @cc = sort values %$cc;
	$cc = '';
	if (@cc) {
		if ($obfs) {
			push(@arg, map {
				my $addr = $_;
				obfuscate_addrs($ibx, $addr, '$(echo .)');
				"--cc=$addr";
			} @cc);
		} else {
			$cc = '&Cc=' . uri_escape_utf8(join(',', @cc));
			push(@arg, map { "--cc=$_" } @cc);
		}
	}

	push @arg, "--subject=".squote_maybe($subj_raw);

	# I'm not sure if address obfuscation and mailto: links can
	# be made compatible; and address obfuscation is misguided,
	# anyways.
	return (\@arg, '', $reply_to_all) if $obfs;

	# keep `@' instead of using `%40' for RFC 6068
	utf8::encode($to);
	$to =~ s!([^A-Za-z0-9\-\._~\@])!$URI::Escape::escapes{$1}!ge;

	# order matters, Subject is the least important header,
	# so it is last in case it's lost/truncated in a copy+paste
	my $href = "mailto:$to?In-Reply-To=$irt${cc}&Subject=$subj";

	(\@arg, ascii_html($href), $reply_to_all);
}

1;
