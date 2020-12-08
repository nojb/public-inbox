# Copyright (C) 2017-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Filter for lists.ruby-lang.org trailers
package PublicInbox::Filter::RubyLang;
use base qw(PublicInbox::Filter::Base);
use strict;
use warnings;
use PublicInbox::MID qw(mids);

my $l1 = qr/Unsubscribe:\s
	<mailto:ruby-\w+-request\@ruby-lang\.org\?subject=unsubscribe>/x;
my $l2 = qr{<http://lists\.ruby-lang\.org/cgi-bin/mailman/options/ruby-\w+>};

sub new {
	my ($class, %opts) = @_;
	my $altid = delete $opts{-altid};
	my $self = $class->SUPER::new(%opts);
	my $ibx = $self->{ibx};
	# altid = serial:ruby-core:file=msgmap.sqlite3
	if (!$altid && $ibx && $ibx->{altid}) {
		$altid ||= $ibx->{altid}->[0];
	}
	if ($altid) {
		require PublicInbox::AltId;
		$self->{-altid} = PublicInbox::AltId->new($ibx, $altid, 1);
	}
	$self;
}

sub scrub_part ($) {
	my ($part) = @_;
	my $ct = $part->content_type;
	if (!$ct || $ct =~ m{\btext/plain\b}i) {
		my $s = eval { $part->body_str };
		if (defined $s && $s =~ s/\n?$l1\n$l2\n\z//os) {
			$part->body_str_set($s);
			return 1;
		}
	}
	0;
}

sub scrub {
	my ($self, $mime, $for_remove) = @_;
	# no msg_iter here, msg_iter is only for read-only access
	if (my @sub = $mime->subparts) {
		my $changed = 0;
		$changed |= scrub_part($_) for @sub;
		$mime->parts_set(\@sub) if $changed;
	} else {
		scrub_part($mime);
	}
	my $altid = $self->{-altid};
	if ($altid && !$for_remove) {
		my $hdr = $mime->header_obj;
		my $mids = mids($hdr);
		return $self->REJECT('Message-ID missing') unless (@$mids);
		my @v = $hdr->header_raw('X-Mail-Count');
		my $n;
		foreach (@v) {
			/\A\s*([0-9]+)\s*\z/ or next;
			$n = $1;
			last;
		}
		unless (defined $n) {
			return $self->REJECT('X-Mail-Count not numeric');
		}
		foreach my $mid (@$mids) {
			my $r = $altid->mm_alt->mid_set($n, $mid);
			next if $r == 0;
			last;
		}
	}
	$self->ACCEPT($mime);
}

sub delivery {
	my ($self, $mime) = @_;
	$self->scrub($mime);
}

1;
