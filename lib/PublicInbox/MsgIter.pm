# Copyright (C) 2016-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# read-only utilities for Email::MIME
package PublicInbox::MsgIter;
use strict;
use warnings;
use base qw(Exporter);
our @EXPORT = qw(msg_iter msg_part_text);

# This becomes PublicInbox::MIME->each_part:
# Like Email::MIME::walk_parts, but this is:
# * non-recursive
# * passes depth and indices to the iterator callback
sub em_each_part ($$;$$) {
	my ($mime, $cb, $cb_arg, $do_undef) = @_;
	my @parts = $mime->subparts;
	if (@parts) {
		$mime = $_[0] = undef if $do_undef; # saves some memory
		my $i = 0;
		@parts = map { [ $_, 1, ++$i ] } @parts;
		while (my $p = shift @parts) {
			my ($part, $depth, $idx) = @$p;
			my @sub = $part->subparts;
			if (@sub) {
				$depth++;
				$i = 0;
				@sub = map {
					[ $_, $depth, "$idx.".(++$i) ]
				} @sub;
				@parts = (@sub, @parts);
			} else {
				$cb->($p, $cb_arg);
			}
		}
	} else {
		$cb->([$mime, 0, 1], $cb_arg);
	}
}

# Use this when we may accept Email::MIME from user scripts
# (not just PublicInbox::MIME)
sub msg_iter ($$;$$) { # $_[0] = PublicInbox::MIME/Email::MIME-like obj
	my (undef, $cb, $cb_arg, $once) = @_;
	if (my $ep = $_[0]->can('each_part')) { # PublicInbox::{MIME,*}
		$ep->($_[0], $cb, $cb_arg, $once);
	} else { # for compatibility with existing Email::MIME users:
		em_each_part($_[0], $cb, $cb_arg, $once);
	}
}

sub msg_part_text ($$) {
	my ($part, $ct) = @_;

	# TODO: we may offer a separate sub for people who need to index
	# HTML-only mail, but the majority of HTML mail is multipart/alternative
	# with a text part which we don't have to waste cycles decoding
	return if $ct =~ m!\btext/x?html\b!;

	my $s = eval { $part->body_str };
	my $err = $@;

	# text/plain is the default, multipart/mixed happened a few
	# times when it should not have been:
	#   <87llgalspt.fsf@free.fr>
	#   <200308111450.h7BEoOu20077@mail.osdl.org>
	# But also do not try this with ->{is_submsg} (message/rfc822),
	# since a broken multipart/mixed inside a message/rfc822 part
	# has not been seen in the wild, yet...
	if ($err && ($ct =~ m!\btext/\b!i ||
			(!$part->{is_submsg} &&
				$ct =~ m!\bmultipart/mixed\b!i) ) ) {
		my $cte = $part->header_raw('Content-Transfer-Encoding');
		if (defined($cte) && $cte =~ /\b7bit\b/i) {
			$s = $part->body;
			$err = undef if $s =~ /\A[[:ascii:]]+\z/s;
		} else {
			# Try to assume UTF-8 because Alpine seems to
			# do wacky things and set charset=X-UNKNOWN
			$part->charset_set('UTF-8');
			$s = eval { $part->body_str };
		}

		# If forcing charset=UTF-8 failed,
		# caller will warn further down...
		$s = $part->body if $@;
	} elsif ($err && $ct =~ m!\bapplication/octet-stream\b!i) {
		# Some unconfigured/poorly-configured MUAs will set
		# application/octet-stream even for all text attachments.
		# Try to see if it's printable text that we can index
		# and display:
		$s = $part->body;
		utf8::decode($s);
		undef($s =~ /[^\p{XPosixPrint}\s]/s ? $s : $err);
	}
	($s, $err);
}

# returns an array of quoted or unquoted sections
sub split_quotes {
	# some editors don't put trailing newlines at the end,
	# make sure split_quotes can work:
	$_[0] .= "\n" if substr($_[0], -1) ne "\n";

	# Quiet "Complex regular subexpression recursion limit" warning
	# in case an inconsiderate sender quotes 32K of text at once.
	# The warning from Perl is harmless for us since our callers can
	# tolerate less-than-ideal matches which work within Perl limits.
	no warnings 'regexp';
	split(/((?:^>[^\n]*\n)+)/sm, $_[0]);
}

1;
