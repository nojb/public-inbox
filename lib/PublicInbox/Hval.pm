# Copyright (C) 2014, Eric Wong <normalperson@yhbt.net> and all contributors
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
#
# represents a header value in various forms
package PublicInbox::Hval;
use strict;
use warnings;
use fields qw(raw -as_utf8);
use Encode qw(find_encoding);
use CGI qw(escapeHTML);
use URI::Escape qw(uri_escape);

my $enc_utf8 = find_encoding('utf8');
my $enc_ascii = find_encoding('us-ascii');

sub new {
	my ($class, $raw) = @_;
	my $self = fields::new($class);

	# we never care about leading/trailing whitespace
	$raw =~ s/\A\s*//;
	$raw =~ s/\s*\z//;
	$self->{raw} = $raw;
	$self;
}

sub new_msgid {
	my ($class, $raw) = @_;
	$raw =~ s/\A<//;
	$raw =~ s/>\z//;
	$class->new($raw);
}

sub new_oneline {
	my ($class, $raw) = @_;
	$raw = '' unless defined $raw;
	$raw =~ tr/\t\n / /s; # squeeze spaces
	$raw =~ tr/\r//d; # kill CR
	$class->new($raw);
}

sub as_utf8 {
	my ($self) = @_;
	$self->{-as_utf8} ||= $enc_utf8->encode($self->{raw});
}

sub ascii_html { $enc_ascii->encode(escapeHTML($_[0]), Encode::HTMLCREF) }

sub as_html { ascii_html($_[0]->as_utf8) }
sub as_href { ascii_html(uri_escape($_[0]->as_utf8)) }

1;
