# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Lazy MIME parser, it still slurps the full message but keeps short
# lifetimes.  Unlike Email::MIME, it doesn't pre-split multipart
# messages or do any up-front parsing of headers besides splitting
# the header string from the body.
#
# Contains ideas and code from Email::Simple and Email::MIME
# (Perl Artistic License, GPL-1+)
#
# This aims to replace Email::MIME for our purposes, similar API
# but internal field names are differ if they're not 100%-compatible.
#
# Includes some proposed fixes for Email::MIME:
# - header-less sub parts - https://github.com/rjbs/Email-MIME/issues/14
# - "0" as boundary - https://github.com/rjbs/Email-MIME/issues/63
#
# $self = {
#	bdy => scalar ref for body (may be undef),
#	hdr => scalar ref for header,
#	crlf => "\n" or "\r\n" (scalar, not a ref),
#
#	# filled in during ->each_part
#	ct => hash ref returned by parse_content_type
# }
package PublicInbox::Eml;
use strict;
use v5.10.1;
use Carp qw(croak);
use Encode qw(find_encoding); # stdlib
use Text::Wrap qw(wrap); # stdlib, we need Perl 5.6+ for $huge
use MIME::Base64 3.05; # Perl 5.10.0 / 5.9.2
use MIME::QuotedPrint 3.05; # ditto

my $MIME_Header = find_encoding('MIME-Header');

use PublicInbox::EmlContentFoo qw(parse_content_type parse_content_disposition);
$PublicInbox::EmlContentFoo::STRICT_PARAMS = 0;

our $mime_parts_limit = 1000; # same as SpamAssassin (not in postfix AFAIK)

# the rest of the limit names are taken from postfix:
our $mime_nesting_limit = 20; # seems enough, Perl sucks, here
our $mime_boundary_length_limit = 2048; # same as postfix
our $header_size_limit = 102400; # same as postfix

my %MIME_ENC = (qp => \&enc_qp, base64 => \&encode_base64);
my %MIME_DEC = (qp => \&dec_qp, base64 => \&decode_base64);
$MIME_ENC{quotedprint} = $MIME_ENC{'quoted-printable'} = $MIME_ENC{qp};
$MIME_DEC{quotedprint} = $MIME_DEC{'quoted-printable'} = $MIME_DEC{qp};
$MIME_ENC{$_} = \&identity_codec for qw(7bit 8bit binary);

my %DECODE_ADDRESS = map {
	($_ => 1, "Resent-$_" => 1)
} qw(From To Cc Sender Reply-To Bcc);
my %DECODE_FULL = (
	Subject => 1,
	'Content-Description' => 1,
	'Content-Type' => 1, # not correct, but needed, oh well
);
our %STR_TYPE = (text => 1);
our %STR_SUBTYPE = (plain => 1, html => 1);

# message/* subtypes we descend into
our %MESSAGE_DESCEND = (
	news => 1, # RFC 1849 (obsolete, but archives are forever)
	rfc822 => 1, # RFC 2046
	rfc2822 => 1, # gmime handles this (but not rfc5322)
	global => 1, # RFC 6532
);

my %re_memo;
sub re_memo ($) {
	my ($k) = @_;
	# Do not normalize $k with lc/uc; instead strive to keep
	# capitalization in our codebase consistent.
	$re_memo{$k} ||= qr/^\Q$k\E:[ \t]*([^\n]*\r?\n # 1st line
					# continuation lines:
					(?:[^:\n]*?[ \t]+[^\n]*\r?\n)*)
					/ismx
}

sub hdr_truncate ($) {
	my $len = length($_[0]);
	substr($_[0], $header_size_limit, $len) = '';
	my $end = rindex($_[0], "\n");
	if ($end >= 0) {
		++$end;
		substr($_[0], $end, $len) = '';
		warn "header of $len bytes truncated to $end bytes\n";
	} else {
		$_[0] = '';
		warn <<EOF
header of $len bytes without `\\n' within $header_size_limit ignored
EOF
	}
}

# compatible with our uses of Email::MIME
sub new {
	my $ref = ref($_[1]) ? $_[1] : \(my $cpy = $_[1]);
	# substr() can modify the first arg in-place and to avoid
	# memcpy/memmove on a potentially large scalar.  It does need
	# to make a copy for $hdr, though.  Idea stolen from Email::Simple.

	# We also prefer index() on common LFLF emails since it's faster
	# and re scan can bump RSS by length($$ref) on big strings
	if (index($$ref, "\r\n") < 0 && (my $pos = index($$ref, "\n\n")) >= 0) {
		# likely on *nix
		my $hdr = substr($$ref, 0, $pos + 2, ''); # sv_chop on $$ref
		chop($hdr); # lower SvCUR
		hdr_truncate($hdr) if length($hdr) > $header_size_limit;
		bless { hdr => \$hdr, crlf => "\n", bdy => $ref }, __PACKAGE__;
	} elsif ($$ref =~ /\r?\n(\r?\n)/s) {
		my $hdr = substr($$ref, 0, $+[0], ''); # sv_chop on $$ref
		substr($hdr, -(length($1))) = ''; # lower SvCUR
		hdr_truncate($hdr) if length($hdr) > $header_size_limit;
		bless { hdr => \$hdr, crlf => $1, bdy => $ref }, __PACKAGE__;
	} elsif ($$ref =~ /^[a-z0-9-]+[ \t]*:/ims && $$ref =~ /(\r?\n)\z/s) {
		# body is optional :P
		my $hdr = substr($$ref, 0, $header_size_limit + 1);
		hdr_truncate($hdr) if length($hdr) > $header_size_limit;
		bless { hdr => \$hdr, crlf => $1 }, __PACKAGE__;
	} else { # nothing useful
		my $hdr = $$ref = '';
		bless { hdr => \$hdr, crlf => "\n" }, __PACKAGE__;
	}
}

sub new_sub {
	my (undef, $ref) = @_;
	# special case for messages like <85k5su9k59.fsf_-_@lola.goethe.zz>
	$$ref =~ /\A(\r?\n)/s or return new(undef, $ref);
	my $hdr = substr($$ref, 0, $+[0], ''); # sv_chop on $$ref
	bless { hdr => \$hdr, crlf => $1, bdy => $ref }, __PACKAGE__;
}

# same output as Email::Simple::Header::header_raw, but we extract
# headers on-demand instead of parsing them into a list which
# requires O(n) lookups anyways
sub header_raw {
	my $re = re_memo($_[1]);
	my @v = (${ $_[0]->{hdr} } =~ /$re/g);
	for (@v) {
		# for compatibility w/ Email::Simple::Header,
		s/\s+\z//s;
		s/\A\s+//s;
		s/\r?\n[ \t]*/ /gs;
	}
	wantarray ? @v : $v[0];
}

# pick the first Content-Type header to match Email::MIME behavior.
# It's usually the right one based on historical archives.
sub ct ($) {
	# PublicInbox::EmlContentFoo::content_type:
	$_[0]->{ct} //= parse_content_type(header($_[0], 'Content-Type'));
}

# returns a queue of sub-parts iff it's worth descending into
sub mp_descend ($$) {
	my ($self, $nr) = @_; # or $once for top-level
	my $ct = ct($self);
	my $type = lc($ct->{type});
	if ($type eq 'message' && $MESSAGE_DESCEND{lc($ct->{subtype})}) {
		my $nxt = new(undef, body_raw($self));
		$self->{-call_cb} = $nxt->{is_submsg} = 1;
		return [ $nxt ];
	}
	return if $type ne 'multipart';
	my $bnd = $ct->{attributes}->{boundary} // return; # single-part
	return if $bnd eq '' || length($bnd) >= $mime_boundary_length_limit;
	$bnd = quotemeta($bnd);

	# this is a multipart message that didn't get descended into in
	# public-inbox <= 1.5.0, so ensure we call the user callback for
	# this part to not break PSGI downloads.
	$self->{-call_cb} = $self->{is_submsg};

	# "multipart" messages can exist w/o a body
	my $bdy = ($nr ? delete($self->{bdy}) : \(body_raw($self))) or return;

	# Cut at the the first epilogue, not subsequent ones.
	# *sigh* just the regexp match alone seems to bump RSS by
	# length($$bdy) on a ~30M string:
	my $epilogue_missing;
	if ($$bdy =~ /(?:\r?\n)?^--$bnd--[ \t]*\r?$/sm) {
		substr($$bdy, $-[0]) = '';
	} else {
		$epilogue_missing = 1;
	}

	# *Sigh* split() doesn't work in-place and return CoW strings
	# because Perl wants to "\0"-terminate strings.  So split()
	# again bumps RSS by length($$bdy)

	# Quiet warning for "Complex regular subexpression recursion limit"
	# in case we get many empty parts, it's harmless in this case
	no warnings 'regexp';
	my ($pre, @parts) = split(/(?:\r?\n)?(?:^--$bnd[ \t]*\r?\n)+/ms,
				$$bdy,
				# + 3 since we don't want the last part
				# processed to include any other excluded
				# parts ($nr starts at 1, and I suck at math)
				$mime_parts_limit + 3 - $nr);

	if (@parts) { # the usual path if we got this far:
		undef $bdy; # release memory ASAP if $nr > 0

		# compatibility with Email::MIME
		$parts[-1] =~ s/\n\r?\n\z/\n/s if $epilogue_missing;

		# ignore empty parts
		@parts = map { new_sub(undef, \$_) } grep /[^ \t\r\n]/s, @parts;

		# Keep "From: someone..." from preamble in old,
		# buggy versions of git-send-email, otherwise drop it
		# There's also a case where quoted text showed up in the
		# preamble
		# <20060515162817.65F0F1BBAE@citi.umich.edu>
		unshift(@parts, new_sub(undef, \$pre)) if index($pre, ':') >= 0;
		return \@parts;
	}
	# "multipart", but no boundary found, treat as single part
	$self->{bdy} //= $bdy;
	undef;
}

# $p = [ \@parts, $depth, $idx ]
# $idx[0] grows as $depth grows, $idx[1] == $p->[-1] == current part
# (callers need to be updated)
# \@parts is a queue which empties when we're done with a parent part

# same usage as PublicInbox::MsgIter::msg_iter
# $cb - user-supplied callback sub
# $arg - user-supplied arg (think pthread_create)
# $once - unref body scalar during iteration
# $all - used by IMAP server, only
sub each_part {
	my ($self, $cb, $arg, $once, $all) = @_;
	my $p = mp_descend($self, $once // 0) or
					return $cb->([$self, 0, 1], $arg);

	$cb->([$self, 0, 0], $arg) if ($all || $self->{-call_cb}); # rare

	$p = [ $p, 0 ];
	my @s; # our virtual stack
	my $nr = 0;
	while ((scalar(@{$p->[0]}) || ($p = pop @s)) &&
			++$nr <= $mime_parts_limit) {
		++$p->[-1]; # bump index
		my (undef, @idx) = @$p;
		@idx = (join('.', @idx));
		my $depth = ($idx[0] =~ tr/././) + 1;
		my $sub = shift @{$p->[0]};
		if ($depth < $mime_nesting_limit &&
				(my $nxt = mp_descend($sub, $nr))) {
			push(@s, $p) if scalar @{$p->[0]};
			$p = [ $nxt, @idx, 0 ];
			($all || $sub->{-call_cb}) and
				$cb->([$sub, $depth, @idx], $arg);
		} else { # a leaf node
			$cb->([$sub, $depth, @idx], $arg);
		}
	}
}

sub enc_qp {
	# prevent MIME::QuotedPrint from encoding CR as =0D since it's
	# against RFCs and breaks MUAs
	$_[0] =~ s/\r\n/\n/sg;
	encode_qp($_[0], "\r\n");
}

sub dec_qp {
	# RFC 2822 requires all lines to end in CRLF, though... :<
	$_[0] = decode_qp($_[0]);
	$_[0] =~ s/\n/\r\n/sg;
	$_[0]
}

sub identity_codec { $_[0] }

########### compatibility section for existing Email::MIME uses #########

sub header_obj {
	bless { hdr => $_[0]->{hdr}, crlf => $_[0]->{crlf} }, __PACKAGE__;
}

sub subparts {
	my ($self) = @_;
	my $parts = mp_descend($self, 0) or return ();
	my $bnd = ct($self)->{attributes}->{boundary} // die 'BUG: no boundary';
	my $bdy = $self->{bdy};
	if ($$bdy =~ /\A(.*?)(?:\r?\n)?^--\Q$bnd\E[ \t]*\r?$/sm) {
		$self->{preamble} = $1;
	}
	if ($$bdy =~ /^--\Q$bnd\E--[ \t]*\r?\n(.+)\z/sm) {
		$self->{epilogue} = $1;
	}
	@$parts;
}

sub parts_set {
	my ($self, $parts) = @_;

	# we can't fully support what Email::MIME does,
	# just what our filter code needs:
	my $bnd = ct($self)->{attributes}->{boundary} // die <<EOF;
->parts_set not supported for single-part messages
EOF
	my $crlf = $self->{crlf};
	my $fin_bnd = "$crlf--$bnd--$crlf";
	$bnd = "$crlf--$bnd$crlf";
	${$self->{bdy}} = join($bnd,
				delete($self->{preamble}) // '',
				map { $_->as_string } @$parts
				) .
				$fin_bnd .
				(delete($self->{epilogue}) // '');
	undef;
}

sub body_set {
	my ($self, $body) = @_;
	my $bdy = $self->{bdy} = ref($body) ? $body : \$body;
	if (my $cte = header_raw($self, 'Content-Transfer-Encoding')) {
		my $enc = $MIME_ENC{lc($cte)} or croak("can't encode `$cte'");
		$$bdy = $enc->($$bdy); # in-place
	}
	undef;
}

sub body_str_set {
	my ($self, $str) = @_;
	my $cs = ct($self)->{attributes}->{charset} //
		croak('body_str was given, but no charset is defined');
	my $enc = find_encoding($cs) // croak "unknown encoding `$cs'";
	my $tmp;
	{
		my @w;
		local $SIG{__WARN__} = sub { push @w, @_ };
		$tmp = $enc->encode($str, Encode::FB_WARN);
		croak(@w) if @w;
	};
	body_set($self, \$tmp);
}

sub content_type { scalar header($_[0], 'Content-Type') }

# we only support raw header_set
sub header_set {
	my ($self, $pfx, @vals) = @_;
	my $re = re_memo($pfx);
	my $hdr = $self->{hdr};
	return $$hdr =~ s!$re!!g if !@vals;
	$pfx .= ': ';
	my $len = 78 - length($pfx);
	@vals = map {;
		# folding differs from Email::Simple::Header,
		# we favor tabs for visibility (and space savings :P)
		if (length($_) >= $len && (/\n[^ \t]/s || !/\n/s)) {
			local $Text::Wrap::columns = $len;
			local $Text::Wrap::huge = 'overflow';
			$pfx . wrap('', "\t", $_) . $self->{crlf};
		} else {
			$pfx . $_ . $self->{crlf};
		}
	} @vals;
	$$hdr =~ s!$re!shift(@vals) // ''!ge; # replace current headers, first
	$$hdr .= join('', @vals); # append any leftovers not replaced
	# wantarray ? @_[2..$#_] : $_[2]; # Email::Simple::Header compat
	undef; # we don't care for the return value
}

# note: we only call this method on Subject
sub header_str_set {
	my ($self, $name, @vals) = @_;
	for (@vals) {
		next unless /[^\x20-\x7e]/;
		# 39: int((75 - length("Subject: =?UTF-8?B?".'?=') ) / 4) * 3;
		s/(.{1,39})/
			my $x = $1;
			utf8::encode($x); # to octets
			'=?UTF-8?B?'.encode_base64($x, '').'?='
		/xges;
	}
	header_set($self, $name, @vals);
}

sub mhdr_decode ($) {
	eval { $MIME_Header->decode($_[0], Encode::FB_DEFAULT) } // $_[0];
}

sub filename {
	my $dis = header_raw($_[0], 'Content-Disposition');
	my $attrs = parse_content_disposition($dis)->{attributes};
	my $fn = $attrs->{filename};
	$fn = ct($_[0])->{attributes}->{name} if !defined($fn) || $fn eq '';
	(defined($fn) && $fn =~ /=\?/) ? mhdr_decode($fn) : $fn;
}

sub xs_addr_str { # helper for ->header / ->header_str
	for (@_) { # array from header_raw()
		next unless /=\?/;
		my @g = parse_email_groups($_); # [ foo => [ E::A::X, ... ]
		for (my $i = 0; $i < @g; $i += 2) {
			if (defined($g[$i]) && $g[$i] =~ /=\?/) {
				$g[$i] = mhdr_decode($g[$i]);
			}
			my $addrs = $g[$i + 1];
			for my $eax (@$addrs) {
				for my $m (qw(phrase comment)) {
					my $v = $eax->$m;
					$eax->$m(mhdr_decode($v)) if
							$v && $v =~ /=\?/;
				}
			}
		}
		$_ = format_email_groups(@g);
	}
}

eval {
	require Email::Address::XS;
	Email::Address::XS->import(qw(parse_email_groups format_email_groups));
	1;
} or do {
	# fallback to just decoding everything, because parsing
	# email addresses correctly w/o C/XS is slow
	%DECODE_FULL = (%DECODE_FULL, %DECODE_ADDRESS);
	%DECODE_ADDRESS = ();
};

*header = \&header_str;
sub header_str {
	my ($self, $name) = @_;
	my @v = header_raw($self, $name);
	if ($DECODE_ADDRESS{$name}) {
		xs_addr_str(@v);
	} elsif ($DECODE_FULL{$name}) {
		for (@v) {
			$_ = mhdr_decode($_) if /=\?/;
		}
	}
	wantarray ? @v : $v[0];
}

sub body_raw { ${$_[0]->{bdy} // \''}; }

sub body {
	my $raw = body_raw($_[0]);
	my $cte = header_raw($_[0], 'Content-Transfer-Encoding') or return $raw;
	($cte) = ($cte =~ /([a-zA-Z0-9\-]+)/) or return $raw; # For S/MIME, etc
	my $dec = $MIME_DEC{lc($cte)} or return $raw;
	$dec->($raw);
}

sub body_str {
	my ($self) = @_;
	my $ct = ct($self);
	my $cs = $ct->{attributes}->{charset} // do {
		($STR_TYPE{$ct->{type}} && $STR_SUBTYPE{$ct->{subtype}}) and
			return body($self);
		croak("can't get body as a string for ",
			join("\n\t", header_raw($self, 'Content-Type')));
	};
	my $enc = find_encoding($cs) or croak "unknown encoding `$cs'";
	my $tmp = body($self);
	# workaround https://rt.cpan.org/Public/Bug/Display.html?id=139622
	my @w;
	local $SIG{__WARN__} = sub { push @w, @_ };
	my $ret = $enc->decode($tmp, Encode::FB_WARN);
	croak(@w) if @w;
	$ret;
}

sub as_string {
	my ($self) = @_;
	my $ret = ${ $self->{hdr} };
	return $ret unless defined($self->{bdy});
	$ret .= $self->{crlf};
	$ret .= ${$self->{bdy}};
}

# Unlike Email::MIME::charset_set, this only changes the parsed
# representation of charset used for search indexing and HTML display.
# This does NOT affect what ->as_string returns.
sub charset_set {
	ct($_[0])->{attributes}->{charset} = $_[1];
}

sub crlf { $_[0]->{crlf} // "\n" }

sub raw_size {
	my ($self) = @_;
	my $len = length(${$self->{hdr}});
	defined($self->{bdy}) and
		$len += length(${$self->{bdy}}) + length($self->{crlf});
	$len;
}

# warnings to ignore when handling spam mailboxes and maybe other places
sub warn_ignore {
	my $s = "@_";
	# Email::Address::XS warnings
	$s =~ /^Argument contains empty /
	|| $s =~ /^Element at index [0-9]+.*? contains /
	# PublicInbox::MsgTime
	|| $s =~ /^bogus TZ offset: .+?, ignoring and assuming \+0000/
	|| $s =~ /^bad Date: .+? in /
	# Encode::Unicode::UTF7
	|| $s =~ /^Bad UTF7 data escape at /
}

# this expects to be RHS in this assignment: "local $SIG{__WARN__} = ..."
sub warn_ignore_cb {
	my $cb = $SIG{__WARN__} // \&CORE::warn;
	sub { $cb->(@_) unless warn_ignore(@_) }
}

sub willneed { re_memo($_) for @_ }

willneed(qw(From To Cc Date Subject Content-Type In-Reply-To References
		Message-ID X-Alt-Message-ID));

1;
