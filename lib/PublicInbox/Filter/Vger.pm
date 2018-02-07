# Copyright (C) 2016-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Filter for vger.kernel.org list trailer
package PublicInbox::Filter::Vger;
use base qw(PublicInbox::Filter::Base);
use strict;
use warnings;

my $l0 = qr/-+/; # older messages only had one '-'
my $l1 =
 qr/To unsubscribe from this list: send the line "unsubscribe [\w-]+" in/;
my $l2 = qr/the body of a message to majordomo\@vger\.kernel\.org/;
my $l3 =
  qr!More majordomo info at +http://vger\.kernel\.org/majordomo-info\.html!;

# only LKML had this, and LKML nowadays has no list trailer since Jan 2016
my $l4 = qr!Please read the FAQ at +http://www\.tux\.org/lkml/!;

sub scrub {
	my ($self, $mime) = @_;
	my $s = $mime->as_string;

	# the vger appender seems to only work on the raw string,
	# so in multipart (e.g. GPG-signed) messages, the list trailer
	# becomes invisible to MIME-aware email clients.
	if ($s =~ s/$l0\n$l1\n$l2\n$l3\n($l4\n)?\z//os) {
		$mime = PublicInbox::MIME->new(\$s);
	}
	$self->ACCEPT($mime);
}

sub delivery {
	my ($self, $mime) = @_;
	$self->scrub($mime);
}

1;
