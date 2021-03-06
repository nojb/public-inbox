# Copyright (C) 2017-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Filter for lists.ruby-lang.org trailers
package PublicInbox::Filter::RubyLang;
use base qw(PublicInbox::Filter::Base);
use strict;
use warnings;

my $l1 = qr/Unsubscribe:\s
	<mailto:ruby-\w+-request\@ruby-lang\.org\?subject=unsubscribe>/x;
my $l2 = qr{<http://lists\.ruby-lang\.org/cgi-bin/mailman/options/ruby-\w+>};

sub new {
	my ($class, %opts) = @_;
	my $altid = delete $opts{-altid};
	my $self = $class->SUPER::new(%opts);
	my $ibx = $self->{-inbox};
	# altid = serial:ruby-core:file=msgmap.sqlite3
	if (!$altid && $ibx && $ibx->{altid}) {
		$altid ||= $ibx->{altid}->[0];
	}
	if ($altid) {
		require PublicInbox::MID; # mid_clean
		require PublicInbox::AltId;
		$self->{-altid} = PublicInbox::AltId->new($ibx, $altid, 1);
	}
	$self;
}

sub scrub {
	my ($self, $mime) = @_;
	# no msg_iter here, that is only for read-only access
	$mime->walk_parts(sub {
		my ($part) = $_[0];
		my $ct = $part->content_type;
		if (!$ct || $ct =~ m{\btext/plain\b}i) {
			my $s = eval { $part->body_str };
			if (defined $s && $s =~ s/\n?$l1\n$l2\n\z//os) {
				$part->body_str_set($s);
			}
		}
	});
	my $altid = $self->{-altid};
	if ($altid) {
		my $hdr = $mime->header_obj;
		my $mid = $hdr->header_raw('Message-ID');
		unless (defined $mid) {
			return $self->REJECT('Message-Id missing');
		}
		my $n = $hdr->header_raw('X-Mail-Count');
		if (!defined($n) || $n !~ /\A\s*\d+\s*\z/) {
			return $self->REJECT('X-Mail-Count not numeric');
		}
		$mid = PublicInbox::MID::mid_clean($mid);
		$altid->{mm_alt}->mid_set($n, $mid);
	}
	$self->ACCEPT($mime);
}

sub delivery {
	my ($self, $mime) = @_;
	$self->scrub($mime);
}

1;
