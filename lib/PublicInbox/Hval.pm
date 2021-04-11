# Copyright (C) 2014-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# represents a header value in various forms.  Used for HTML generation
# in our web interface(s)
package PublicInbox::Hval;
use strict;
use warnings;
use Encode qw(find_encoding);
use PublicInbox::MID qw/mid_clean mid_escape/;
use base qw/Exporter/;
our @EXPORT_OK = qw/ascii_html obfuscate_addrs to_filename src_escape
		to_attr prurl mid_href fmt_ts ts2str/;
use POSIX qw(strftime);
my $enc_ascii = find_encoding('us-ascii');

# safe-ish acceptable filename pattern for portability
our $FN = '[a-zA-Z0-9][a-zA-Z0-9_\-\.]+[a-zA-Z0-9]'; # needs \z anchor

sub mid_href { ascii_html(mid_escape($_[0])) }

# some of these overrides are standard C escapes so they're
# easy-to-understand when rendered.
my %escape_sequence = (
	"\x00" => '\\0', # NUL
	"\x07" => '\\a', # bell
	"\x08" => '\\b', # backspace
	"\x09" => "\t", # obvious to show as-is
	"\x0a" => "\n", # obvious to show as-is
	"\x0b" => '\\v', # vertical tab
	"\x0c" => '\\f', # form feed
	"\x0d" => '\\r', # carriage ret (not preceding \n)
	"\x1b" => '^[', # ASCII escape (mutt seems to escape this way)
	"\x7f" => '\\x7f', # DEL
);

my %xhtml_map = (
	'"' => '&#34;',
	'&' => '&#38;',
	"'" => '&#39;',
	'<' => '&lt;',
	'>' => '&gt;',
);

$xhtml_map{chr($_)} = sprintf('\\x%02x', $_) for (0..31);
%xhtml_map = (%xhtml_map, %escape_sequence);

# for post-processing the output of highlight.pm and perhaps other
# highlighers in the future
sub src_escape ($) {
	$_[0] =~ s/\r\n/\n/sg;
	$_[0] =~ s/&apos;/&#39;/sg; # workaround https://bugs.debian.org/927409
	$_[0] =~ s/([\x7f\x00-\x1f])/$xhtml_map{$1}/sge;
	$_[0] = $enc_ascii->encode($_[0], Encode::HTMLCREF);
}

sub ascii_html {
	my ($s) = @_;
	$s =~ s/([<>&'"\x7f\x00-\x1f])/$xhtml_map{$1}/sge;
	$enc_ascii->encode($s, Encode::HTMLCREF);
}

# returns a protocol-relative URL string
sub prurl ($$) {
	my ($env, $u) = @_;
	if (ref($u) eq 'ARRAY') {
		my $h = $env->{HTTP_HOST} // $env->{SERVER_NAME};
		my @host_match = grep(/\b\Q$h\E\b/, @$u);
		$u = $host_match[0] // $u->[0];
		# fall through to below:
	}
	index($u, '//') == 0 ? "$env->{'psgi.url_scheme'}:$u" : $u;
}

# for misguided people who believe in this stuff, give them a
# substitution for '.'
# &#8228; &#183; and &#890; were also candidates:
#   https://public-inbox.org/meta/20170615015250.GA6484@starla/
# However, &#8226; was chosen to make copy+paste errors more obvious
sub obfuscate_addrs ($$;$) {
	my $ibx = $_[0];
	my $repl = $_[2] // '&#8226;';
	my $re = $ibx->{-no_obfuscate_re}; # regex of domains
	my $addrs = $ibx->{-no_obfuscate}; # { $address => 1 }
	$_[1] =~ s#(\S+)\@([\w\-]+\.[\w\.\-]+)#
		my ($pfx, $domain) = ($1, $2);
		if (index($pfx, '://') > 0 || $pfx !~ s/([\w\.\+=\-]+)\z//) {
			"$pfx\@$domain";
		} else {
			my $user = $1;
			my $addr = "$user\@$domain";
			if ($addrs->{$addr} || ((defined($re) &&
						$domain =~ $re))) {
				$pfx.$addr;
			} else {
				$domain =~ s!([^\.]+)\.!$1$repl!;
				$pfx . $user . '@' . $domain
			}
		}
		#sge;
}

# like format_sanitized_subject in git.git pretty.c with '%f' format string
sub to_filename ($) {
	my $s = (split(/\n/, $_[0]))[0] // return; # empty string => undef
	$s =~ s/[^A-Za-z0-9_\.]+/-/g;
	$s =~ tr/././s;
	$s =~ s/[\.\-]+\z//;
	$s =~ s/\A[\.\-]+//;
	$s eq '' ? undef : $s;
}

# convert a filename (or any string) to HTML attribute

my %ESCAPES = map { chr($_) => sprintf('::%02x', $_) } (0..255);
$ESCAPES{'/'} = ':'; # common

sub to_attr ($) {
	my ($str) = @_;

	# git would never do this to us:
	return if index($str, '//') >= 0;

	my $first = '';
	utf8::encode($str); # to octets
	if ($str =~ s/\A([^A-Ya-z])//ms) { # start with a letter
		  $first = sprintf('Z%02x', ord($1));
	}
	$str =~ s/([^A-Za-z0-9_\.\-])/$ESCAPES{$1}/egms;
	utf8::decode($str); # allow wide chars
	$first . $str;
}

# for the t= query parameter passed to overview DB
sub ts2str ($) { strftime('%Y%m%d%H%M%S', gmtime($_[0])) };

# human-friendly format
sub fmt_ts ($) { strftime('%Y-%m-%d %k:%M', gmtime($_[0])) }

1;
