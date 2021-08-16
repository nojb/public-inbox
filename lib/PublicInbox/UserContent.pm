# Copyright (C) 2019-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Self-updating module containing a sample CSS for client-side
# customization by users of public-inbox.  Used by Makefile.PL
package PublicInbox::UserContent;
use strict;
use warnings;

# this sub is updated automatically:
sub CSS () {
	<<'_'
	/*
	 * CC0-1.0 <https://creativecommons.org/publicdomain/zero/1.0/legalcode>
	 * Dark color scheme using 216 web-safe colors, inspired
	 * somewhat by the default color scheme in mutt.
	 * It reduces eyestrain for me, and energy usage for all:
	 * https://en.wikipedia.org/wiki/Light-on-dark_color_scheme
	 */
	* { font-size: 100% !important;
		font-family: monospace !important;
		background:#000 !important;
		color:#ccc !important }
	pre { white-space: pre-wrap !important }

	/*
	 * Underlined links add visual noise which make them hard-to-read.
	 * Use colors to make them stand out, instead.
	 */
	a:link { color:#69f !important;
		text-decoration:none !important }
	a:visited { color:#96f !important }

	/* quoted text in emails gets a different color */
	*.q { color:#09f !important }

	/*
	 * these may be used with cgit <https://git.zx2c4.com/cgit/>, too.
	 * (cgit uses <div>, public-inbox uses <span>)
	 */
	*.add { color:#0ff !important } /* diff post-image lines */
	*.del { color:#f0f !important } /* diff pre-image lines */
	*.head { color:#fff !important } /* diff header (metainformation) */
	*.hunk { color:#c93 !important } /* diff hunk-header */

	/*
	 * highlight 3.x colors (tested 3.18) for displaying blobs.
	 * This doesn't use most of the colors available, as I find too
	 * many colors overwhelming, so the default is commented out.
	 */
	.hl.num { color:#f30 !important } /* number */
	.hl.esc { color:#f0f !important } /* escape character */
	.hl.str { color:#f30 !important } /* string */
	.hl.ppc { color:#f0f !important } /* preprocessor */
	.hl.pps { color:#f30 !important } /* preprocessor string */
	.hl.slc { color:#09f !important } /* single-line comment */
	.hl.com { color:#09f !important } /* multi-line comment */
	/* .hl.opt { color:#ccc !important } */ /* operator */
	/* .hl.ipl { color:#ccc !important } */ /* interpolation */

	/* keyword groups kw[a-z] */
	.hl.kwa { color:#ff0 !important }
	.hl.kwb { color:#0f0 !important }
	.hl.kwc { color:#ff0 !important }
	/* .hl.kwd { color:#ccc !important } */

	/* line-number (unused by public-inbox) */
	/* .hl.lin { color:#ccc !important } */
_
}
# end of auto-updated sub

# return a sample CSS
sub sample ($$) {
	my ($ibx, $env) = @_;
	my $url_prefix = $ibx->base_url($env);
	my $preamble = <<"";
/*
 * Firefox users: this goes in \$PROFILE_FOLDER/chrome/userContent.css
 * where \$PROFILE_FOLDER is platform-specific
 *
 * cf. http://kb.mozillazine.org/UserContent.css
 *     http://kb.mozillazine.org/Profile_folder_-_Firefox
 *
 * Users of dillo can remove the entire lines with "moz-only"
 * in them and place the resulting file in ~/.dillo/style.css
 */
\@-moz-document url-prefix($url_prefix) { /* moz-only */

	$preamble . CSS() . "\n} /* moz-only */\n";
}

# Auto-update this file based on the contents of a CSS file:
# usage: perl -I lib __FILE__ contrib/css/216dark.css
# (See Makefile.PL)
if (scalar(@ARGV) == 1 && -r __FILE__) {
	open my $ro, '<', $ARGV[0] or die $!;
	my $css = do { local $/; <$ro> } or die $!;

	# indent one level:
	$css =~ s/^([ \t]*\S)/\t$1/smg;

	# "!important" overrides whatever the BOFH sets:
	$css =~ s/;/ !important;/sg;
	$css =~ s/(\w) \}/$1 !important }/msg;

	open my $rw, '+<', __FILE__ or die $!;
	my $out = do { local $/; <$rw> } or die $!;
	$css =~ s/; /;\n\t\t/g;
	$out =~ s/^sub CSS.*^_\n\}/sub CSS () {\n\t<<'_'\n${css}_\n}/sm;
	seek $rw, 0, 0;
	print $rw $out or die $!;
	close $rw or die $!;
}

1;
