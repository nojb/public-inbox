# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# used by PublicInbox::View
# This adds CSS spans for diff highlighting.
# It also generates links for ViewVCS + SolverGit to show
# (or reconstruct) blobs.

package PublicInbox::ViewDiff;
use strict;
use v5.10.1;
use parent qw(Exporter);
our @EXPORT_OK = qw(flush_diff);
use URI::Escape qw(uri_escape_utf8);
use PublicInbox::Hval qw(ascii_html to_attr);
use PublicInbox::Git qw(git_unquote);

my $UNSAFE = "^A-Za-z0-9\-\._~/"; # '/' + $URI::Escape::Unsafe{RFC3986}
my $OID_NULL = '0{7,}';
my $OID_BLOB = '[a-f0-9]{7,}';
my $LF = qr!\n!;
my $ANY = qr![^\n]!;
my $FN = qr!(?:"?[^/\n]+/[^\n]+|/dev/null)!;

# cf. git diff.c :: get_compact_summary
my $DIFFSTAT_COMMENT =
	qr/(?: *\((?:new|gone|(?:(?:new|mode) [\+\-][lx]))\))? *\z/s;
my $NULL_TO_BLOB = qr/^(index $OID_NULL\.\.)($OID_BLOB)\b/ms;
my $BLOB_TO_NULL = qr/^index ($OID_BLOB)(\.\.$OID_NULL)\b/ms;
my $BLOB_TO_BLOB = qr/^index ($OID_BLOB)\.\.($OID_BLOB)/ms;
our $EXTRACT_DIFFS = qr/(
		(?:	# begin header stuff, don't capture filenames, here,
			# but instead wait for the --- and +++ lines.
			(?:^diff\x20--git\x20$FN\x20$FN$LF)

			# old mode || new mode || copy|rename|deleted|...
			(?:^[a-z]$ANY+$LF)*
		)? # end of optional stuff, everything below is required
		^index\x20($OID_BLOB)\.\.($OID_BLOB)$ANY*$LF
		^---\x20($FN)$LF
		^\+{3}\x20($FN)$LF)/msx;
our $IS_OID = qr/\A$OID_BLOB\z/s;

# link to line numbers in blobs
sub diff_hunk ($$$$) {
	my ($dst, $dctx, $ca, $cb) = @_;
	my ($oid_a, $oid_b, $spfx) = @$dctx{qw(oid_a oid_b spfx)};

	if (defined($spfx) && defined($oid_a) && defined($oid_b)) {
		my ($n) = ($ca =~ /^-([0-9]+)/);
		$n = defined($n) ? "#n$n" : '';

		$$dst .= qq(@@ <a\nhref="$spfx$oid_a/s/$dctx->{Q}$n">$ca</a>);

		($n) = ($cb =~ /^\+([0-9]+)/);
		$n = defined($n) ? "#n$n" : '';
		$$dst .= qq( <a\nhref="$spfx$oid_b/s/$dctx->{Q}$n">$cb</a> @@);
	} else {
		$$dst .= "@@ $ca $cb @@";
	}
}

sub oid ($$$) {
	my ($dctx, $spfx, $oid) = @_;
	defined($spfx) ? qq(<a\nhref="$spfx$oid/s/$dctx->{Q}">$oid</a>) : $oid;
}

# returns true if diffstat anchor written, false otherwise
sub anchor0 ($$$$) {
	my ($dst, $ctx, $fn, $rest) = @_;

	my $orig = $fn;

	# normal git diffstat output is impossible to parse reliably
	# without --numstat, and that isn't the default for format-patch.
	# So only do best-effort handling of renames for common cases;
	# which works well in practice. If projects put "=>", or trailing
	# spaces in filenames, oh well :P
	$fn =~ s/$DIFFSTAT_COMMENT//;
	$fn =~ s/\{(?:.+) => (.+)\}/$1/ or $fn =~ s/.* => (.+)/$1/;
	$fn = git_unquote($fn);

	# long filenames will require us to check in anchor1()
	push(@{$ctx->{-long_path}}, $fn) if $fn =~ s!\A\.\.\./?!!;

	if (defined(my $attr = to_attr($ctx->{-apfx}.$fn))) {
		$ctx->{-anchors}->{$attr} = 1;
		my $spaces = ($orig =~ s/( +)\z//) ? $1 : '';
		$$dst .= " <a\nid=i$attr\nhref=#$attr>" .
			ascii_html($orig) . '</a>' . $spaces .
			$ctx->{-linkify}->to_html($rest);
		return 1;
	}
	undef;
}

# returns "diff --git" anchor destination, undef otherwise
sub anchor1 ($$) {
	my ($ctx, $pb) = @_;
	my $attr = to_attr($ctx->{-apfx}.$pb) // return;

	my $ok = delete $ctx->{-anchors}->{$attr};

	# unlikely, check the end of long path names we captured,
	# assume diffstat and diff output follow the same order,
	# and ignore different ordering (could be malicious input)
	unless ($ok) {
		my $fn = shift(@{$ctx->{-long_path}}) // return;
		$pb =~ /\Q$fn\E\z/s or return;
		$attr = to_attr($ctx->{-apfx}.$fn) // return;
		$ok = delete $ctx->{-anchors}->{$attr} // return;
	}
	$ok ? "<a\nhref=#i$attr\nid=$attr>diff</a> --git" : undef
}

sub diff_header ($$$) {
	my ($x, $ctx, $top) = @_;
	my (undef, undef, $pa, $pb) = splice(@$top, 0, 4); # ignore oid_{a,b}
	my $spfx = $ctx->{-spfx};
	my $dctx = { spfx => $spfx };

	# get rid of leading "a/" or "b/" (or whatever --{src,dst}-prefix are)
	$pa = (split(m'/', git_unquote($pa), 2))[1] if $pa ne '/dev/null';
	$pb = (split(m'/', git_unquote($pb), 2))[1] if $pb ne '/dev/null';
	if ($pa eq $pb && $pb ne '/dev/null') {
		$dctx->{Q} = "?b=".uri_escape_utf8($pb, $UNSAFE);
	} else {
		my @q;
		if ($pb ne '/dev/null') {
			push @q, 'b='.uri_escape_utf8($pb, $UNSAFE);
		}
		if ($pa ne '/dev/null') {
			push @q, 'a='.uri_escape_utf8($pa, $UNSAFE);
		}
		$dctx->{Q} = '?'.join('&amp;', @q);
	}

	# linkify early and all at once, since we know the following
	# subst ops on $$x won't need further escaping:
	$$x = $ctx->{-linkify}->to_html($$x);

	# no need to capture oid_a and oid_b on add/delete,
	# we just linkify OIDs directly via s///e in conditional
	if ($$x =~ s/$NULL_TO_BLOB/$1 . oid($dctx, $spfx, $2)/e) {
		push @{$ctx->{-qry}->{dfpost}}, $2;
	} elsif ($$x =~ s/$BLOB_TO_NULL/'index '.oid($dctx, $spfx, $1).$2/e) {
		push @{$ctx->{-qry}->{dfpre}}, $1;
	} elsif ($$x =~ $BLOB_TO_BLOB) {
		# modification-only, not add/delete:
		# linkify hunk headers later using oid_a and oid_b
		@$dctx{qw(oid_a oid_b)} = ($1, $2);
		push @{$ctx->{-qry}->{dfpre}}, $1;
		push @{$ctx->{-qry}->{dfpost}}, $2;
	} else {
		warn "BUG? <$$x> had no ^index line";
	}
	$$x =~ s!^diff --git!anchor1($ctx, $pb) // 'diff --git'!ems;
	my $dst = $ctx->{obuf};
	$$dst .= qq(<span\nclass="head">);
	$$dst .= $$x;
	$$dst .= '</span>';
	$dctx;
}

sub diff_before_or_after ($$) {
	my ($ctx, $x) = @_;
	my $linkify = $ctx->{-linkify};
	my $dst = $ctx->{obuf};
	if (exists $ctx->{-anchors} && $$x =~ /\A(.*?) # likely "---\n"
			# diffstat lines:
			((?:^\x20(?:[^\n]+?)(?:\x20+\|\x20[^\n]*\n))+)
			(\x20[0-9]+\x20files?\x20)changed,([^\n]+\n)
			(.*?)\z/msx) { # notes, commit message, etc
		undef $$x;
		my @x = ($5, $4, $3, $2, $1);
		$$dst .= $linkify->to_html(pop @x); # uninteresting prefix
		for my $l (split(/^/m, pop(@x))) { # per-file diffstat lines
			$l =~ /^ (.+)( +\| .*\z)/s and
				anchor0($dst, $ctx, $1, $2) and next;
			$$dst .= $linkify->to_html($l);
		}
		$$dst .= $x[2]; # $3 /^ \d+ files? /
		my $ch = $ctx->{changed_href} // '#related';
		$$dst .= qq(<a href="$ch">changed</a>,);
		$$dst .= ascii_html($x[1]); # $4: insertions/deletions
		$$dst .= $linkify->to_html($x[0]); # notes, commit message, etc
	} else {
		$$dst .= $linkify->to_html($$x);
	}
}

# callers must do CRLF => LF conversion before calling this
sub flush_diff ($$) {
	my ($ctx, $cur) = @_;

	my @top = split($EXTRACT_DIFFS, $$cur);
	undef $$cur; # free memory

	my $linkify = $ctx->{-linkify};
	my $dst = $ctx->{obuf};
	my $dctx; # {}, keys: Q, oid_a, oid_b

	while (defined(my $x = shift @top)) {
		if (scalar(@top) >= 4 &&
				$top[1] =~ $IS_OID &&
				$top[0] =~ $IS_OID) {
			$dctx = diff_header(\$x, $ctx, \@top);
		} elsif ($dctx) {
			my $after = '';

			# Quiet "Complex regular subexpression recursion limit"
			# warning.  Perl will truncate matches upon hitting
			# that limit, giving us more (and shorter) scalars than
			# would be ideal, but otherwise it's harmless.
			#
			# We could replace the `+' metacharacter with `{1,100}'
			# to limit the matches ourselves to 100, but we can
			# let Perl do it for us, quietly.
			no warnings 'regexp';

			for my $s (split(/((?:(?:^\+[^\n]*\n)+)|
					(?:(?:^-[^\n]*\n)+)|
					(?:^@@ [^\n]+\n))/xsm, $x)) {
				if (!defined($dctx)) {
					$after .= $s;
				} elsif ($s =~ s/\A@@ (\S+) (\S+) @@//) {
					$$dst .= qq(<span\nclass="hunk">);
					diff_hunk($dst, $dctx, $1, $2);
					$$dst .= $linkify->to_html($s);
					$$dst .= '</span>';
				} elsif ($s =~ /\A\+/) {
					$$dst .= qq(<span\nclass="add">);
					$$dst .= $linkify->to_html($s);
					$$dst .= '</span>';
				} elsif ($s =~ /\A-- $/sm) { # email sig starts
					$dctx = undef;
					$after .= $s;
				} elsif ($s =~ /\A-/) {
					$$dst .= qq(<span\nclass="del">);
					$$dst .= $linkify->to_html($s);
					$$dst .= '</span>';
				} else {
					$$dst .= $linkify->to_html($s);
				}
			}
			diff_before_or_after($ctx, \$after) unless $dctx;
		} else {
			diff_before_or_after($ctx, \$x);
		}
	}
}

1;
