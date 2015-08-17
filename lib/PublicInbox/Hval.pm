# Copyright (C) 2014, Eric Wong <normalperson@yhbt.net> and all contributors
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
#
# represents a header value in various forms
package PublicInbox::Hval;
use strict;
use warnings;
use fields qw(raw href);
use Encode qw(find_encoding);
use URI::Escape qw(uri_escape_utf8);
use PublicInbox::MID qw/mid_clean mid_compressed/;

my $enc_ascii = find_encoding('us-ascii');

sub new {
	my ($class, $raw, $href) = @_;
	my $self = fields::new($class);

	# we never care about leading/trailing whitespace
	$raw =~ s/\A\s*//;
	$raw =~ s/\s*\z//;
	$self->{raw} = $raw;
	$self->{href} = defined $href ? $href : $raw;
	$self;
}

sub new_msgid {
	my ($class, $msgid) = @_;
	$msgid = mid_clean($msgid);
	$class->new($msgid, mid_compressed($msgid));
}

sub new_oneline {
	my ($class, $raw) = @_;
	$raw = '' unless defined $raw;
	$raw =~ tr/\t\n / /s; # squeeze spaces
	$raw =~ tr/\r//d; # kill CR
	$class->new($raw);
}

my %xhtml_map = (
	'"' => '&#34;',
	'&' => '&#38;',
	"'" => '&#39;',
	'<' => '&lt;',
	'>' => '&gt;',
);

sub ascii_html {
	my ($s) = @_;
	$s =~ s/\r\n/\n/sg; # fixup bad line endings
	$s =~ s/([<>&'"])/$xhtml_map{$1}/ge;
	$enc_ascii->encode($s, Encode::HTMLCREF);
}

sub as_html { ascii_html($_[0]->{raw}) }
sub as_href { ascii_html(uri_escape_utf8($_[0]->{href})) }

sub raw {
	if (defined $_[1]) {
		$_[0]->{raw} = $_[1];
	} else {
		$_[0]->{raw};
	}
}

1;
