# Copyright (C) 2016-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::Linkify;

{
	my $l = PublicInbox::Linkify->new;
	my $u = 'http://example.com/url-with-trailing-period';
	my $s = $u . '.';
	$s = $l->linkify_1($s);
	$s = $l->linkify_2($s);
	is($s, qq(<a\nhref="$u">$u</a>.), 'trailing period not in URL');
}

{
	my $l = PublicInbox::Linkify->new;
	my $u = 'http://i-forgot-trailing-slash.example.com';
	my $s = $u;
	$s = $l->linkify_1($s);
	$s = $l->linkify_2($s);
	is($s, qq(<a\nhref="$u">$u</a>), 'missing trailing slash OK');
}

# handle URLs in parenthesized statements
{
	my $l = PublicInbox::Linkify->new;
	my $u = 'http://example.com/';
	my $s = "(see: $u)";
	$s = $l->linkify_1($s);
	$s = $l->linkify_2($s);
	is($s, qq{(see: <a\nhref="$u">$u</a>)}, 'trailing ) not in URL');
}

{
	my $l = PublicInbox::Linkify->new;
	my $u = 'http://example.com/url-with-trailing-semicolon';
	my $s = $u . ';';
	$s = $l->linkify_1($s);
	$s = $l->linkify_2($s);
	is($s, qq(<a\nhref="$u">$u</a>;), 'trailing semicolon not in URL');
}

{
	my $l = PublicInbox::Linkify->new;
	my $u = 'http://example.com/url-with-(parens)';
	my $s = "hello $u world";
	$s = $l->linkify_1($s);
	$s = $l->linkify_2($s);
	is($s, qq(hello <a\nhref="$u">$u</a> world), 'URL preserved');

	$s = "$u. hi";
	$s = $l->linkify_1($s);
	$s = $l->linkify_2($s);
	is($s, qq(<a\nhref="$u">$u</a>. hi), 'paired () in URL OK');

	$u .= "?query=a";
	$s = "hello $u world";
	$s = $l->linkify_1($s);
	$s = $l->linkify_2($s);
	is($s, qq(hello <a\nhref="$u">$u</a> world), 'query preserved');

	$u .= "#fragment";
	$s = "hello $u world";
	$s = $l->linkify_1($s);
	$s = $l->linkify_2($s);
	is($s, qq(hello <a\nhref="$u">$u</a> world),
	  'query + fragment preserved');

	$u = "http://example.com/";
	$s = "hello $u world";
	$s = $l->linkify_1($s);
	$s = $l->linkify_2($s);
	is($s, qq(hello <a\nhref="$u">$u</a> world), "root URL preserved");

	$u = "http://example.com/#fragment";
	$s = "hello $u world";
	$s = $l->linkify_1($s);
	$s = $l->linkify_2($s);
	is($s, qq(hello <a\nhref="$u">$u</a> world), "root + fragment");
}

# Markdown compatibility
{
	my $l = PublicInbox::Linkify->new;
	my $u = 'http://example.com/';
	my $s = "[markdown]($u)";
	$s = $l->linkify_1($s);
	$s = $l->linkify_2($s);
	is($s, qq![markdown](<a\nhref="$u">$u</a>)!, 'Markdown-compatible');

	$s = qq![markdown]($u "title")!;
	$s = $l->linkify_1($s);
	$s = $l->linkify_2($s);
	is($s, qq![markdown](<a\nhref="$u">$u</a> "title")!,
		'Markdown title compatible');

	$s = qq![markdown]($u).!;
	$s = $l->linkify_1($s);
	$s = $l->linkify_2($s);
	is($s, qq![markdown](<a\nhref="$u">$u</a>).!,
		'Markdown-compatible end of sentence');
}

# Perl and Ruby code compatibility
{
	my $l = PublicInbox::Linkify->new;
	my $u = 'http://example.com/';
	foreach my $q ("'%s'", '"%s"', 'q!%s!', 'q(%s)') {
		# Perl
		my $s = sprintf("my \$var = $q;", $u);
		$s = $l->linkify_1($s);
		$s = $l->linkify_2($s);
		like($s, qr/>\Q$u\E</, "no quote($q) in URL");

		# applies to Ruby, too
		$s = sprintf("$q,", $u);
		$s = $l->linkify_1($s);
		$s = $l->linkify_2($s);
		like($s, qr/>\Q$u\E</, "no quote($q) in URL array");
	}
}

# dangling ')'  cf. see MaintNotes in git.git todo branch
{
	my $l = PublicInbox::Linkify->new;
	my $s = '(see http://example.com/).';
	$s = $l->linkify_1($s);
	$s = $l->linkify_2($s);
	like($s, qr!\(see <a[^>]+>http://example\.com/</a>\)\.!s,
		'punctuation with unpaired ) OK')
}

if ('IDN example: <ACDB98F4-178C-43C3-99C4-A1D03DD6A8F5@sb.org>') {
	my $hc = '&#26376;';
	my $u = "http://www.\x{6708}.example.com/";
	my $s = $u;
	my $l = PublicInbox::Linkify->new;
	$s = $l->linkify_1($s);
	$s = $l->linkify_2($s);
	my $expect = qq{<a
href="http://www.$hc.example.com/">http://www.$hc.example.com/</a>};
	is($s, $expect, 'IDN message escaped properly');
}

{
	my $false_positive = 'LINKIFY'.('A' x 40);
	is(PublicInbox::Linkify->new->to_html($false_positive),
		$false_positive, 'false-positive left as-is');
}
done_testing();
