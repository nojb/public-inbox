# Copyright (C) 2014-2018 all contributors <meta@public-inbox.org>
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
our @EXPORT_OK = qw/ascii_html obfuscate_addrs to_filename src_escape/;

my $enc_ascii = find_encoding('us-ascii');

sub new {
	my ($class, $raw, $href) = @_;

	# we never care about trailing whitespace
	$raw =~ s/\s*\z//;
	bless {
		raw => $raw,
		href => defined $href ? $href : $raw,
	}, $class;
}

sub new_msgid {
	my ($class, $msgid) = @_;
	$class->new($msgid, mid_escape($msgid));
}

sub new_oneline {
	my ($class, $raw) = @_;
	$raw = '' unless defined $raw;
	$raw =~ tr/\t\n / /s; # squeeze spaces
	$raw =~ tr/\r//d; # kill CR
	$class->new($raw);
}

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

sub src_escape ($) {
	$_[0] =~ s/\r\n/\n/sg;
	$_[0] =~ s/([\x7f\x00-\x1f])/$xhtml_map{$1}/sge;
	$_[0] = $enc_ascii->encode($_[0], Encode::HTMLCREF);
}

sub ascii_html {
	my ($s) = @_;
	$s =~ s/\r\n/\n/sg; # fixup bad line endings
	$s =~ s/([<>&'"\x7f\x00-\x1f])/$xhtml_map{$1}/sge;
	$enc_ascii->encode($s, Encode::HTMLCREF);
}

sub as_html { ascii_html($_[0]->{raw}) }

sub raw {
	if (defined $_[1]) {
		$_[0]->{raw} = $_[1];
	} else {
		$_[0]->{raw};
	}
}

sub prurl {
	my ($env, $u) = @_;
	index($u, '//') == 0 ? "$env->{'psgi.url_scheme'}:$u" : $u;
}

# for misguided people who believe in this stuff, give them a
# substitution for '.'
# &#8228; &#183; and &#890; were also candidates:
#   https://public-inbox.org/meta/20170615015250.GA6484@starla/
# However, &#8226; was chosen to make copy+paste errors more obvious
sub obfuscate_addrs ($$;$) {
	my $ibx = $_[0];
	my $repl = $_[2] || '&#8226;';
	my $re = $ibx->{-no_obfuscate_re}; # regex of domains
	my $addrs = $ibx->{-no_obfuscate}; # { adddress => 1 }
	$_[1] =~ s/(([\w\.\+=\-]+)\@([\w\-]+\.[\w\.\-]+))/
		my ($addr, $user, $domain) = ($1, $2, $3);
		if ($addrs->{$addr} || ((defined $re && $domain =~ $re))) {
			$addr;
		} else {
			$domain =~ s!([^\.]+)\.!$1$repl!;
			$user . '@' . $domain
		}
		/sge;
}

# like format_sanitized_subject in git.git pretty.c with '%f' format string
sub to_filename ($) {
	my ($s, undef) = split(/\n/, $_[0]);
	$s =~ s/[^A-Za-z0-9_\.]+/-/g;
	$s =~ tr/././s;
	$s =~ s/[\.\-]+\z//;
	$s =~ s/\A[\.\-]+//;
	$s
}

1;
