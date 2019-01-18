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
use PublicInbox::Hval qw(ascii_html);
use PublicInbox::Git qw(git_unquote);

sub DSTATE_INIT () { 0 }
sub DSTATE_STAT () { 1 } # TODO
sub DSTATE_HEAD () { 2 } # /^diff --git /, /^index /, /^--- /, /^\+\+\+ /
sub DSTATE_HUNK () { 3 } # /^@@ /
sub DSTATE_CTX () { 4 } # /^ /
sub DSTATE_ADD () { 5 } # /^\+/
sub DSTATE_DEL () { 6 } # /^\-/
sub UNSAFE () { "^A-Za-z0-9\-\._~/" }

my $OID_NULL = '0{7,40}';
my $OID_BLOB = '[a-f0-9]{7,40}';
my $PATH_A = '"?a/.+|/dev/null';
my $PATH_B = '"?b/.+|/dev/null';

sub to_html ($$) {
	$_[0]->linkify_1($_[1]);
	$_[0]->linkify_2(ascii_html($_[1]));
}

# link to line numbers in blobs
sub diff_hunk ($$$$) {
	my ($dctx, $spfx, $ca, $cb) = @_;
	my $oid_a = $dctx->{oid_a};
	my $oid_b = $dctx->{oid_b};

	(defined($oid_a) && defined($oid_b)) or return "@@ $ca $cb @@";

	my ($n) = ($ca =~ /^-(\d+)/);
	$n = defined($n) ? do { ++$n; "#n$n" } : '';

	my $rv = qq(@@ <a\nhref=$spfx$oid_a/s$dctx->{Q}$n>$ca</a>);

	($n) = ($cb =~ /^\+(\d+)/);
	$n = defined($n) ? do { ++$n; "#n$n" } : '';

	$rv .= qq( <a\nhref=$spfx$oid_b/s$dctx->{Q}$n>$cb</a> @@);
}

sub flush_diff ($$$$) {
	my ($dst, $spfx, $linkify, $diff) = @_;
	my $state = DSTATE_INIT;
	my $dctx = { Q => '' }; # {}, keys: oid_a, oid_b, path_a, path_b

	foreach my $s (@$diff) {
		if ($s =~ /^ /) {
			if ($state == DSTATE_HUNK || $state == DSTATE_ADD ||
			    $state == DSTATE_DEL || $state == DSTATE_HEAD) {
				$$dst .= "</span><span\nclass=ctx>";
				$state = DSTATE_CTX;
			}
			$$dst .= to_html($linkify, $s);
		} elsif ($s =~ /^-- $/) { # email signature begins
			if ($state != DSTATE_INIT) {
				$state = DSTATE_INIT;
				$$dst .= '</span>';
			}
			$$dst .= $s;
		} elsif ($s =~ m!^diff --git ($PATH_A) ($PATH_B)$!) {
			if ($state != DSTATE_HEAD) {
				my ($pa, $pb) = ($1, $2);
				$$dst .= '</span>' if $state != DSTATE_INIT;
				$$dst .= "<span\nclass=head>";
				$state = DSTATE_HEAD;
				$pa = (split('/', git_unquote($pa), 2))[1];
				$pb = (split('/', git_unquote($pb), 2))[1];
				$dctx = {
					Q => "?b=".uri_escape_utf8($pb, UNSAFE),
				};
				if ($pa ne $pb) {
					$dctx->{Q} .=
					     "&a=".uri_escape_utf8($pa, UNSAFE);
				}
			}
			$$dst .= to_html($linkify, $s);
		} elsif ($s =~ s/^(index $OID_NULL\.\.)($OID_BLOB)\b//o) {
			$$dst .= qq($1<a\nhref=$spfx$2/s$dctx->{Q}>$2</a>);
			$$dst .= to_html($linkify, $s) ;
		} elsif ($s =~ s/^index ($OID_NULL)(\.\.$OID_BLOB)\b//o) {
			$$dst .= 'index ';
			$$dst .= qq(<a\nhref=$spfx$1/s$dctx->{Q}>$1</a>$2);
			$$dst .= to_html($linkify, $s);
		} elsif ($s =~ /^index ($OID_BLOB)\.\.($OID_BLOB)/o) {
			$dctx->{oid_a} = $1;
			$dctx->{oid_b} = $2;
			$$dst .= to_html($linkify, $s);
		} elsif ($s =~ s/^@@ (\S+) (\S+) @@//) {
			my ($ca, $cb) = ($1, $2);
			if ($state == DSTATE_HEAD || $state == DSTATE_CTX ||
			    $state == DSTATE_ADD || $state == DSTATE_DEL) {
				$$dst .= "</span><span\nclass=hunk>";
				$state = DSTATE_HUNK;
				$$dst .= diff_hunk($dctx, $spfx, $ca, $cb);
			} else {
				$$dst .= to_html($linkify, "@@ $ca $cb @@");
			}
			$$dst .= to_html($linkify, $s);
		} elsif ($s =~ m!^--- $PATH_A!) {
			if ($state == DSTATE_INIT) { # color only (no oid link)
				$state = DSTATE_HEAD;
				$$dst .= "<span\nclass=head>";
			}
			$$dst .= to_html($linkify, $s);
		} elsif ($s =~ m!^\+{3} $PATH_B!)  {
			if ($state == DSTATE_INIT) { # color only (no oid link)
				$state = DSTATE_HEAD;
				$$dst .= "<span\nclass=head>";
			}
			$$dst .= to_html($linkify, $s);
		} elsif ($s =~ /^\+/) {
			if ($state != DSTATE_ADD && $state != DSTATE_INIT) {
				$$dst .= "</span><span\nclass=add>";
				$state = DSTATE_ADD;
			}
			$$dst .= to_html($linkify, $s);
		} elsif ($s =~ /^-/) {
			if ($state != DSTATE_DEL && $state != DSTATE_INIT) {
				$$dst .= "</span><span\nclass=del>";
				$state = DSTATE_DEL;
			}
			$$dst .= to_html($linkify, $s);
		# ignore the following lines in headers:
		} elsif ($s =~ /^(?:dis)similarity index/ ||
			 $s =~ /^(?:old|new) mode/ ||
			 $s =~ /^(?:deleted|new) file mode/ ||
			 $s =~ /^(?:copy|rename) (?:from|to) / ||
			 $s =~ /^(?:dis)?similarity index /) {
			$$dst .= to_html($linkify, $s);
		} else {
			if ($state != DSTATE_INIT) {
				$$dst .= '</span>';
				$state = DSTATE_INIT;
			}
			$$dst .= to_html($linkify, $s);
		}
	}
	@$diff = ();
	$$dst .= '</span>' if $state != DSTATE_INIT;
	undef;
}

1;
