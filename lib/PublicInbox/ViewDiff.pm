# Copyright (C) 2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# used by PublicInbox::View
# This adds CSS spans for diff highlighting.
# It also generates links for ViewVCS + SolverGit to show
# (or reconstruct) blobs.

package PublicInbox::ViewDiff;
use strict;
use warnings;
use base qw(Exporter);
our @EXPORT_OK = qw(flush_diff);
use URI::Escape qw(uri_escape_utf8);
use PublicInbox::Hval qw(ascii_html to_attr);
use PublicInbox::Git qw(git_unquote);

# keep track of state so we can avoid redundant HTML tags for
# identically-classed lines
sub DSTATE_INIT () { 0 }
sub DSTATE_STAT () { 1 }
sub DSTATE_HEAD () { 2 } # /^diff --git /, /^index /, /^--- /, /^\+\+\+ /
sub DSTATE_CTX () { 3 } # /^ /
sub DSTATE_ADD () { 4 } # /^\+/
sub DSTATE_DEL () { 5 } # /^\-/

# maps the DSTATE_* to CSS class names compatible with what cgit uses:
my @state2class = (
	'', # init
	'', # stat
	'head',
	'', # ctx
	'add',
	'del'
);

sub UNSAFE () { "^A-Za-z0-9\-\._~/" }

my $OID_NULL = '0{7,40}';
my $OID_BLOB = '[a-f0-9]{7,40}';
my $PATH_X = '"?[^/]+/.+|/dev/null';

# cf. git diff.c :: get_compact_summary
my $DIFFSTAT_COMMENT = qr/\((?:new|gone|(?:(?:new|mode) [\+\-][lx]))\)/;

# link to line numbers in blobs
sub diff_hunk ($$$$) {
	my ($dctx, $spfx, $ca, $cb) = @_;
	my $oid_a = $dctx->{oid_a};
	my $oid_b = $dctx->{oid_b};

	(defined($spfx) && defined($oid_a) && defined($oid_b)) or
		return "@@ $ca $cb @@";

	my ($n) = ($ca =~ /^-([0-9]+)/);
	$n = defined($n) ? do { ++$n; "#n$n" } : '';

	my $rv = qq(@@ <a\nhref="$spfx$oid_a/s/$dctx->{Q}$n">$ca</a>);

	($n) = ($cb =~ /^\+([0-9]+)/);
	$n = defined($n) ? do { ++$n; "#n$n" } : '';

	$rv .= qq( <a\nhref="$spfx$oid_b/s/$dctx->{Q}$n">$cb</a> @@);
}

sub oid ($$$) {
	my ($dctx, $spfx, $oid) = @_;
	defined($spfx) ? qq(<a\nhref="$spfx$oid/s/$dctx->{Q}">$oid</a>) : $oid;
}

sub to_state ($$$) {
	my ($dst, $state, $new_state) = @_;
	$$dst .= '</span>' if $state2class[$state];
	$_[1] = $new_state;
	my $class = $state2class[$new_state] or return;
	$$dst .= qq(<span\nclass="$class">);
}

sub anchor0 ($$$$$) {
	my ($dst, $ctx, $linkify, $fn, $rest) = @_;

	my $orig = $fn;

	# normal git diffstat output is impossible to parse reliably
	# without --numstat, and that isn't the default for format-patch.
	# So only do best-effort handling of renames for common cases;
	# which works well in practice. If projects put "=>", or trailing
	# spaces in filenames, oh well :P
	$fn =~ s/(?: *$DIFFSTAT_COMMENT)? *\z//so;
	$fn =~ s/{(?:.+) => (.+)}/$1/ or $fn =~ s/.* => (.+)/$1/;
	$fn = git_unquote($fn);

	# long filenames will require us to walk backwards in anchor1
	if ($fn =~ s!\A\.\.\./?!!) {
		my $lp = $ctx->{-long_path} ||= {};
		$lp->{$fn} = qr/\Q$fn\E\z/s;
	}

	if (my $attr = to_attr($ctx->{-apfx}.$fn)) {
		$ctx->{-anchors}->{$attr} = 1;
		my $spaces = ($orig =~ s/( +)\z//) ? $1 : '';
		$$dst .= " <a\nid=i$attr\nhref=#$attr>" .
			ascii_html($orig) . '</a>' . $spaces .
			$linkify->to_html($rest);
		return 1;
	}
	undef;
}

sub anchor1 ($$$$$) {
	my ($dst, $ctx, $linkify, $pb, $s) = @_;
	my $attr = to_attr($ctx->{-apfx}.$pb) or return;
	my $line = $linkify->to_html($s);

	my $ok = delete $ctx->{-anchors}->{$attr};

	# unlikely, check the end of all long path names we captured:
	unless ($ok) {
		my $lp = $ctx->{-long_path} or return;
		foreach my $fn (keys %$lp) {
			$pb =~ $lp->{$fn} or next;

			delete $lp->{$fn};
			$attr = to_attr($ctx->{-apfx}.$fn) or return;
			$ok = delete $ctx->{-anchors}->{$attr} or return;
			last;
		}
	}
	if ($ok && $line =~ s/^diff //) {
		$$dst .= "<a\nhref=#i$attr\nid=$attr>diff</a> ".$line;
		return 1;
	}
	undef
}

sub missing_diff_git_line ($$) {
	my ($dctx, $pb) = @_;
	# missing "diff --git ..."
	$dctx->{path_b} = $pb;
	$dctx->{Q} = '?b='.uri_escape_utf8($pb, UNSAFE);
	my $pa = $dctx->{path_a};
	if (defined($pa) && $pa ne $pb) {
		$dctx->{Q} .= '&amp;a='. uri_escape_utf8($pa, UNSAFE);
	}
}

sub flush_diff ($$$) {
	my ($dst, $ctx, $linkify) = @_;
	my $diff = $ctx->{-diff};
	my $spfx = $ctx->{-spfx};
	my $state = DSTATE_INIT;
	my $dctx = { Q => '' }; # {}, keys: oid_a, oid_b, path_a, path_b

	foreach my $s (@$diff) {
		if ($s =~ /^---$/) {
			to_state($dst, $state, DSTATE_STAT);
			$$dst .= $s;
		} elsif ($s =~ /^ / || ($s =~ /^$/ && $state >= DSTATE_CTX)) {
			# works for common cases, but not weird/long filenames
			if ($state == DSTATE_STAT &&
					$s =~ /^ (.+)( +\| .*\z)/s) {
				anchor0($dst, $ctx, $linkify, $1, $2) and next;
			} elsif ($state2class[$state]) {
				to_state($dst, $state, DSTATE_CTX);
			}
			$$dst .= $linkify->to_html($s);
		} elsif ($s =~ /^-- $/) { # email signature begins
			$state == DSTATE_INIT or
				to_state($dst, $state, DSTATE_INIT);
			$$dst .= $s;
		} elsif ($s =~ m!^diff --git ($PATH_X) ($PATH_X)$!o) {
			my ($pa, $pb) = ($1, $2);
			if ($state != DSTATE_HEAD) {
				to_state($dst, $state, DSTATE_HEAD);
			}
			$pa = (split('/', git_unquote($pa), 2))[1];
			$pb = (split('/', git_unquote($pb), 2))[1];
			$dctx = {
				Q => "?b=".uri_escape_utf8($pb, UNSAFE),
			};
			if ($pa ne $pb) {
				$dctx->{Q} .= '&amp;a='.
					uri_escape_utf8($pa, UNSAFE);
			}
			anchor1($dst, $ctx, $linkify, $pb, $s) and next;
			$$dst .= $linkify->to_html($s);
		} elsif ($s =~ s/^(index $OID_NULL\.\.)($OID_BLOB)\b//o) {
			$$dst .= $1 . oid($dctx, $spfx, $2);
			$dctx = { Q => '' };
			$$dst .= $linkify->to_html($s) ;
		} elsif ($s =~ s/^index ($OID_BLOB)(\.\.$OID_NULL)\b//o) {
			$$dst .= 'index ' . oid($dctx, $spfx, $1) . $2;
			$dctx = { Q => '' };
			$$dst .= $linkify->to_html($s);
		} elsif ($s =~ /^index ($OID_BLOB)\.\.($OID_BLOB)/o) {
			$dctx->{oid_a} = $1;
			$dctx->{oid_b} = $2;
			$$dst .= $linkify->to_html($s);
		} elsif ($s =~ s/^@@ (\S+) (\S+) @@//) {
			$$dst .= '</span>' if $state2class[$state];
			$$dst .= qq(<span\nclass="hunk">);
			$$dst .= diff_hunk($dctx, $spfx, $1, $2);
			$$dst .= '</span>';
			$state = DSTATE_CTX;
			$$dst .= $linkify->to_html($s);
		} elsif ($s =~ m!^--- ($PATH_X)!o) {
			my $pa = $1;
			$pa = (split('/', git_unquote($pa), 2))[1];
			if (($dctx->{path_a} // '') ne $pa) {
				# missing "diff --git ..." ?
				$dctx->{path_a} = $pa;
			}
			# color only (no oid link) if missing dctx->{oid_*}
			$state <= DSTATE_STAT and
				to_state($dst, $state, DSTATE_HEAD);
			$$dst .= $linkify->to_html($s);
		} elsif ($s =~ m!^\+{3} ($PATH_X)!o) {
			my $pb = $1;
			$pb = (split('/', git_unquote($pb), 2))[1];
			if (($dctx->{path_b} // '') ne $pb) {
				missing_diff_git_line($dctx, $pb);
			}

			# color only (no oid link) if missing dctx->{oid_*}
			$state <= DSTATE_STAT and
				to_state($dst, $state, DSTATE_HEAD);
			$$dst .= $linkify->to_html($s);
		} elsif ($s =~ /^\+/) {
			if ($state != DSTATE_ADD && $state > DSTATE_STAT) {
				to_state($dst, $state, DSTATE_ADD);
			}
			$$dst .= $linkify->to_html($s);
		} elsif ($s =~ /^-/) {
			if ($state != DSTATE_DEL && $state > DSTATE_STAT) {
				to_state($dst, $state, DSTATE_DEL);
			}
			$$dst .= $linkify->to_html($s);
		# ignore the following lines in headers:
		} elsif ($s =~ /^(?:dis)similarity index/ ||
			 $s =~ /^(?:old|new) mode/ ||
			 $s =~ /^(?:deleted|new) file mode/ ||
			 $s =~ /^(?:copy|rename) (?:from|to) / ||
			 $s =~ /^(?:dis)?similarity index /) {
			$$dst .= $linkify->to_html($s);
		} else {
			$state <= DSTATE_STAT or
				to_state($dst, $state, DSTATE_INIT);
			$$dst .= $linkify->to_html($s);
		}
	}
	@$diff = ();
	$$dst .= '</span>' if $state2class[$state];
	undef;
}

1;
