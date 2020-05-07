# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# Copyright (C) 2004- Simon Cozens, Casey West, Ricardo SIGNES
# This library is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.
#
# License: GPL-1.0+ or Artistic-1.0-Perl
#  <https://www.gnu.org/licenses/gpl-1.0.txt>
#  <https://dev.perl.org/licenses/artistic.html>
#
# This license differs from the rest of public-inbox
#
# ABSTRACT: Parse a MIME Content-Type or Content-Disposition Header
#
# This is a fork of the Email::MIME::ContentType 1.022 with
# minor improvements and incompatibilities; namely changes to
# quiet warnings with legacy data.
package PublicInbox::EmlContentFoo;
use strict;
use parent qw(Exporter);
use v5.10.1;

# find_mime_encoding() only appeared in Encode 2.87+ (Perl 5.26+),
# while we support 2.35 shipped with Perl 5.10.1
use Encode 2.35 qw(find_encoding);
my %mime_name_map; # $enc->mime_name => $enc object
BEGIN {
	eval { Encode->import('find_mime_encoding') };
	if ($@) {
		*find_mime_encoding = sub { $mime_name_map{lc($_[0])} };
		%mime_name_map = map {;
			my $enc = find_encoding($_);
			my $m = lc($enc->mime_name // '');
			$m => $enc;
		} Encode->encodings(':all');

		# delete fallback for encodings w/o ->mime_name:
		delete $mime_name_map{''};

		# an extra alias see Encode::MIME::NAME
		$mime_name_map{'utf8'} = find_encoding('UTF-8');
	}
}

our @EXPORT_OK = qw(parse_content_type parse_content_disposition);

our $STRICT_PARAMS = 1;

my $ct_default = 'text/plain; charset=us-ascii';

my $re_token = # US-ASCII except SPACE, CTLs and tspecials ()<>@,;:\\"/[]?=
	qr/[\x21\x23-\x27\x2A\x2B\x2D\x2E\x30-\x39\x41-\x5A\x5E-\x7E]+/;

my $re_token_non_strict = # allow CTLs and above ASCII
	qr/([\x00-\x08\x0B\x0C\x0E-\x1F\x7E-\xFF]+|$re_token)/;

my $re_qtext = # US-ASCII except CR, LF, white space, backslash and quote
	qr/[\x01-\x08\x0B\x0C\x0E-\x1F\x21\x23-\x5B\x5D-\x7E\x7F]/;
my $re_quoted_pair = qr/\\[\x00-\x7F]/;
my $re_quoted_string = qr/"((?:[ \t]*(?:$re_qtext|$re_quoted_pair))*[ \t]*)"/;

my $re_qtext_non_strict = qr/[\x80-\xFF]|$re_qtext/;
my $re_quoted_pair_non_strict = qr/\\[\x00-\xFF]/;
my $re_quoted_string_non_strict =
qr/"((?:[ \t]*(?:$re_qtext_non_strict|$re_quoted_pair_non_strict))*[ \t]*)"/;

my $re_charset = qr/[!"#\$%&'+\-0-9A-Z\\\^_`a-z\{\|\}~]+/;
my $re_language = qr/[A-Za-z]{1,8}(?:-[0-9A-Za-z]{1,8})*/;
my $re_exvalue = qr/($re_charset)?'(?:$re_language)?'(.*)/;

sub parse_content_type {
	my ($ct) = @_;

	# If the header isn't there or is empty, give default answer.
	$ct = $ct_default unless defined($ct) && length($ct);

	_unfold_lines($ct);
	_clean_comments($ct);

	# It is also recommend (sic.) that this default be assumed when a
	# syntactically invalid Content-Type header field is encountered.
	unless ($ct =~ s/^($re_token)\/($re_token)//) {
		unless ($STRICT_PARAMS && $ct =~ s/^($re_token_non_strict)\/
						($re_token_non_strict)//x) {
			#carp "Invalid Content-Type '$ct'";
			return parse_content_type($ct_default);
		}
	}

	my ($type, $subtype) = (lc $1, lc $2);

	_clean_comments($ct);
	$ct =~ s/\s+$//;

	my $attributes = {};
	if ($STRICT_PARAMS && length($ct) && $ct !~ /^;/) {
		# carp "Missing ';' before first Content-Type parameter '$ct'";
	} else {
		$attributes = _process_rfc2231(_parse_attributes($ct));
	}

	{
		type	   => $type,
		subtype	=> $subtype,
		attributes => $attributes,

		# This is dumb.  Really really dumb.  For backcompat. -- rjbs,
		# 2013-08-10
		discrete   => $type,
		composite  => $subtype,
	};
}

my $cd_default = 'attachment';

sub parse_content_disposition {
	my ($cd) = @_;

	$cd = $cd_default unless defined($cd) && length($cd);

	_unfold_lines($cd);
	_clean_comments($cd);

	unless ($cd =~ s/^($re_token)//) {
		unless ($STRICT_PARAMS and $cd =~ s/^($re_token_non_strict)//) {
			#carp "Invalid Content-Disposition '$cd'";
			return parse_content_disposition($cd_default);
		}
	}

	my $type = lc $1;

	_clean_comments($cd);
	$cd =~ s/\s+$//;

	my $attributes = {};
	if ($STRICT_PARAMS && length($cd) && $cd !~ /^;/) {
# carp "Missing ';' before first Content-Disposition parameter '$cd'";
	} else {
		$attributes = _process_rfc2231(_parse_attributes($cd));
	}

	{
		type	   => $type,
		attributes => $attributes,
	};
}

sub _unfold_lines {
	$_[0] =~ s/(?:\r\n|[\r\n])(?=[ \t])//g;
}

sub _clean_comments {
	my $ret = ($_[0] =~ s/^\s+//);
	while (length $_[0]) {
		last unless $_[0] =~ s/^\(//;
		my $level = 1;
		while (length $_[0]) {
			my $ch = substr $_[0], 0, 1, '';
			if ($ch eq '(') {
				$level++;
			} elsif ($ch eq ')') {
				$level--;
				last if $level == 0;
			} elsif ($ch eq '\\') {
				substr $_[0], 0, 1, '';
			}
		}
		# carp "Unbalanced comment" if $level != 0 and $STRICT_PARAMS;
		$ret |= ($_[0] =~ s/^\s+//);
	}
	$ret;
}

sub _process_rfc2231 {
	my ($attribs) = @_;
	my %cont;
	my %encoded;
	foreach (keys %{$attribs}) {
		next unless $_ =~ m/^(.*)\*([0-9])\*?$/;
		my ($attr, $sec) = ($1, $2);
		$cont{$attr}->[$sec] = $attribs->{$_};
		$encoded{$attr}->[$sec] = 1 if $_ =~ m/\*$/;
		delete $attribs->{$_};
	}
	foreach (keys %cont) {
		my $key = $_;
		$key .= '*' if $encoded{$_};
		$attribs->{$key} = join '', @{$cont{$_}};
	}
	foreach (keys %{$attribs}) {
		next unless $_ =~ m/^(.*)\*$/;
		my $key = $1;
		next unless $attribs->{$_} =~ m/^$re_exvalue$/;
		my ($charset, $value) = ($1, $2);
		$value =~ s/%([0-9A-Fa-f]{2})/pack('C', hex($1))/eg;
		if (length $charset) {
			my $enc = find_mime_encoding($charset);
			if (defined $enc) {
				$value = $enc->decode($value);
			# } else {
				#carp "Unknown charset '$charset' in
				#attribute '$key' value";
			}
		}
		$attribs->{$key} = $value;
		delete $attribs->{$_};
	}
	$attribs;
}

sub _parse_attributes {
	local $_ = shift;
	substr($_, 0, 0, '; ') if length $_ and $_ !~ /^;/;
	my $attribs = {};
	while (length $_) {
		s/^;// or $STRICT_PARAMS and do {
			#carp "Missing semicolon before parameter '$_'";
			return $attribs;
		};
		_clean_comments($_);
		unless (length $_) {
			# Some mail software generates a Content-Type like this:
			# "Content-Type: text/plain;"
			# RFC 1521 section 3 says a parameter must exist if
			# there is a semicolon.
			#carp "Extra semicolon after last parameter" if
			#$STRICT_PARAMS;
			return $attribs;
		}
		my $attribute;
		if (s/^($re_token)=//) {
			$attribute = lc $1;
		} else {
			if ($STRICT_PARAMS) {
				# carp "Illegal parameter '$_'";
				return $attribs;
			}
			if (s/^($re_token_non_strict)=//) {
				$attribute = lc $1;
			} else {
				unless (s/^([^;=\s]+)\s*=//) {
					#carp "Cannot parse parameter '$_'";
					return $attribs;
				}
				$attribute = lc $1;
			}
		}
		_clean_comments($_);
		my $value = _extract_attribute_value();
		$attribs->{$attribute} = $value;
		_clean_comments($_);
	}
	$attribs;
}

sub _extract_attribute_value { # EXPECTS AND MODIFIES $_
	my $value;
	while (length $_) {
		if (s/^($re_token)//) {
			$value .= $1;
		} elsif (s/^$re_quoted_string//) {
			my $sub = $1;
			$sub =~ s/\\(.)/$1/g;
			$value .= $sub;
		} elsif ($STRICT_PARAMS) {
			#my $char = substr $_, 0, 1;
			#carp "Unquoted '$char' not allowed";
			return;
		} elsif (s/^($re_token_non_strict)//) {
			$value .= $1;
		} elsif (s/^$re_quoted_string_non_strict//) {
			my $sub = $1;
			$sub =~ s/\\(.)/$1/g;
			$value .= $sub;
		}
		my $erased = _clean_comments($_);
		last if !length $_ or /^;/;
		if ($STRICT_PARAMS) {
			#my $char = substr $_, 0, 1;
			#carp "Extra '$char' found after parameter";
			return;
		}
		if ($erased) {
			# Sometimes semicolon is missing, so check for = char
			last if m/^$re_token_non_strict=/;
			$value .= ' ';
		}
		$value .= substr $_, 0, 1, '';
	}
	$value;
}

1;
__END__
=func parse_content_type

This routine is exported by default.

This routine parses email content type headers according to section 5.1 of RFC
2045 and also RFC 2231 (Character Set and Parameter Continuations).  It returns
a hash as above, with entries for the C<type>, the C<subtype>, and a hash of
C<attributes>.

For backward compatibility with a really unfortunate misunderstanding of RFC
2045 by the early implementors of this module, C<discrete> and C<composite> are
also present in the returned hashref, with the values of C<type> and C<subtype>
respectively.

=func parse_content_disposition

This routine is exported by default.

This routine parses email Content-Disposition headers according to RFC 2183 and
RFC 2231.  It returns a hash as above, with entries for the C<type>, and a hash
of C<attributes>.

=cut
