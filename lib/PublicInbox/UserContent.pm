# Copyright (C) 2019 all contributors <meta@public-inbox.org>
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
	 * Dark color scheme using 216 web-safe colors, inspired
	 * somewhat by the default color scheme in mutt.
	 * It reduces eyestrain for me, and energy usage for all:
	 * https://en.wikipedia.org/wiki/Light-on-dark_color_scheme
	 */
	* { background:#000; color:#ccc }

	/*
	 * Underlined links add visual noise which make them hard-to-read.
	 * Use colors to make them stand out, instead.
	 */
	a { color:#69f; text-decoration:none }
	a:visited { color:#96f }

	/* quoted text gets a different color */
	*.q { color:#09f }

	/*
	 * these may be used with cgit, too
	 * (cgit uses <div>, public-inbox uses <span>)
	 */
	*.add { color:#0ff }
	*.del { color:#f0f }
	*.head { color:#fff }
	*.hunk { color:#c93 }

	/*
	 * highlight 3.x colors (tested 3.18) for displaying blobs.
	 * This doesn't use most of the colors available (I find too many
	 * colors overwhelming), so the #ccc default is commented out.
	 */
	.hl.num { color:#f30 } /* number */
	.hl.esc { color:#f0f } /* escape character */
	.hl.str { color:#f30 } /* string */
	.hl.ppc { color:#f0f } /* preprocessor */
	.hl.pps { color:#f30 } /* preprocessor string */
	.hl.slc { color:#09f } /* single-line comment */
	.hl.com { color:#09f } /* multi-line comment */
	/* .hl.opt { color:#ccc } */ /* operator */
	/* .hl.ipl { color:#ccc } */ /* interpolation */
	/* .hl.lin { color:#ccc } */ /* line-number (unused by public-inbox) */

	/* keyword groups kw[a-z] */
	.hl.kwa { color:#ff0 }
	.hl.kwb { color:#0f0 }
	.hl.kwc { color:#ff0 }
	/* .hl.kwd { color:#ccc } */
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
	use autodie;
	open my $ro, '<', $ARGV[0];
	my $css = do { local $/; <$ro> };
	$css =~ s/^([ \t]*\S)/\t$1/smg;
	open my $rw, '+<', __FILE__;
	my $out = do { local $/; <$rw> };
	$out =~ s/^sub CSS.*^_\n\}/sub CSS () {\n\t<<'_'\n${css}_\n}/sm;
	seek $rw, 0, 0;
	print $rw $out;
}

1;
