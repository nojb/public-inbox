# Copyright (C) 2016-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# read-only utilities for Email::MIME
package PublicInbox::MsgIter;
use strict;
use warnings;
use base qw(Exporter);
our @EXPORT = qw(msg_iter msg_part_text);
use PublicInbox::MIME;

# Like Email::MIME::walk_parts, but this is:
# * non-recursive
# * passes depth and indices to the iterator callback
sub msg_iter ($$) {
	my ($mime, $cb) = @_;
	my @parts = $mime->subparts;
	if (@parts) {
		my $i = 0;
		@parts = map { [ $_, 1, ++$i ] } @parts;
		while (my $p = shift @parts) {
			my ($part, $depth, @idx) = @$p;
			my @sub = $part->subparts;
			if (@sub) {
				$depth++;
				$i = 0;
				@sub = map { [ $_, $depth, @idx, ++$i ] } @sub;
				@parts = (@sub, @parts);
			} else {
				$cb->($p);
			}
		}
	} else {
		$cb->([$mime, 0, 0]);
	}
}

sub msg_part_text ($$) {
	my ($part, $ct) = @_;

	my $s = eval { $part->body_str };
	my $err = $@;

	# text/plain is the default, multipart/mixed happened a few
	# times when it should not have been:
	#   <87llgalspt.fsf@free.fr>
	#   <200308111450.h7BEoOu20077@mail.osdl.org>
	if ($ct =~ m!\btext/plain\b!i || $ct =~ m!\bmultipart/mixed\b!i) {
		# Try to assume UTF-8 because Alpine seems to
		# do wacky things and set charset=X-UNKNOWN
		$part->charset_set('UTF-8');
		$s = eval { $part->body_str };

		# If forcing charset=UTF-8 failed,
		# caller will warn further down...
		$s = $part->body if $@;
	}
	($s, $err);
}

1;
