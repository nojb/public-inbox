# Copyright (C) 2015-2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# based on notmuch, but with no concept of folders, files or flags
#
# Wraps a document inside our Xapian search index.
package PublicInbox::SearchMsg;
use strict;
use warnings;
use Search::Xapian;
use POSIX qw//;
use Date::Parse qw/str2time/;
use PublicInbox::MID qw/mid_clean/;
use PublicInbox::Address;
our $PFX2TERM_RE = undef;
use constant EPOCH_822 => 'Thu, 01 Jan 1970 00:00:00 +0000';
use POSIX qw(strftime);

sub new {
	my ($class, $mime) = @_;
	my $doc = Search::Xapian::Document->new;
	$doc->add_term(PublicInbox::Search::xpfx('type') . 'mail');

	bless { type => 'mail', doc => $doc, mime => $mime }, $class;
}

sub wrap {
	my ($class, $doc, $mid) = @_;
	bless { doc => $doc, mime => undef, mid => $mid }, $class;
}

sub get_val ($$) {
	my ($doc, $col) = @_;
	Search::Xapian::sortable_unserialise($doc->get_value($col));
}

sub load_doc {
	my ($class, $doc) = @_;
	my $data = $doc->get_data or return;
	my $ts = get_val($doc, &PublicInbox::Search::TS);
	utf8::decode($data);
	my ($subj, $from, $refs, $to, $cc, $blob) = split(/\n/, $data);
	bless {
		doc => $doc,
		subject => $subj,
		ts => $ts,
		from => $from,
		references => $refs,
		to => $to,
		cc => $cc,
		blob => $blob,
	}, $class;
}

# :bytes and :lines metadata in RFC 3977
sub bytes ($) { get_val($_[0]->{doc}, &PublicInbox::Search::BYTES) }
sub lines ($) { get_val($_[0]->{doc}, &PublicInbox::Search::LINES) }
sub num ($) { get_val($_[0]->{doc}, &PublicInbox::Search::NUM) }

sub __hdr ($$) {
	my ($self, $field) = @_;
	my $val = $self->{$field};
	return $val if defined $val;

	my $mime = $self->{mime} or return;
	$val = $mime->header($field);
	$val = '' unless defined $val;
	$val =~ tr/\n/ /;
	$val =~ tr/\r//d;
	$self->{$field} = $val;
}

sub subject ($) { __hdr($_[0], 'subject') }
sub to ($) { __hdr($_[0], 'to') }
sub cc ($) { __hdr($_[0], 'cc') }

sub date ($) {
	my ($self) = @_;
	my $date = __hdr($self, 'date');
	return $date if defined $date;
	my $ts = $self->{ts};
	return unless defined $ts;
	$self->{date} = strftime('%a, %d %b %Y %T +0000', gmtime($ts));
}

sub from ($) {
	my ($self) = @_;
	my $from = __hdr($self, 'from');
	if (defined $from && !defined $self->{from_name}) {
		my @n = PublicInbox::Address::names($from);
		$self->{from_name} = join(', ', @n);
	}
	$from;
}

sub from_name {
	my ($self) = @_;
	my $from_name = $self->{from_name};
	return $from_name if defined $from_name;
	$self->from;
	$self->{from_name};
}

sub ts {
	my ($self) = @_;
	$self->{ts} ||= eval { str2time($self->mime->header('Date')) } || 0;
}

sub to_doc_data {
	my ($self, $blob) = @_;
	my @rows = ($self->subject, $self->from, $self->references,
			$self->to, $self->cc);
	push @rows, $blob if defined $blob;
	join("\n", @rows);
}

sub references {
	my ($self) = @_;
	my $x = $self->{references};
	defined $x ? $x : '';
}

sub ensure_metadata {
	my ($self) = @_;
	my $doc = $self->{doc};
	my $end = $doc->termlist_end;

	unless (defined $PFX2TERM_RE) {
		my $or = join('|', keys %PublicInbox::Search::PFX2TERM_RMAP);
		$PFX2TERM_RE = qr/\A($or)/;
	}

	while (my ($pfx, $field) = each %PublicInbox::Search::PFX2TERM_RMAP) {
		# ideally we'd move this out of the loop:
		my $i = $doc->termlist_begin;

		$i->skip_to($pfx);
		if ($i != $end) {
			my $val = $i->get_termname;

			if ($val =~ s/$PFX2TERM_RE//o) {
				$self->{$field} = $val;
			}
		}
	}
}

sub mid ($;$) {
	my ($self, $mid) = @_;

	if (defined $mid) {
		$self->{mid} = $mid;
	} elsif (my $rv = $self->{mid}) {
		$rv;
	} else {
		$self->ensure_metadata; # needed for ghosts
		$self->{mid} ||= $self->_extract_mid;
	}
}

sub _extract_mid { mid_clean(mid_mime($_[0]->mime)) }

sub blob {
	my ($self, $x40) = @_;
	if (defined $x40) {
		$self->{blob} = $x40;
	} else {
		$self->{blob};
	}
}

sub mime {
	my ($self, $mime) = @_;
	if (defined $mime) {
		$self->{mime} = $mime;
	} else {
		# TODO load from git
		$self->{mime};
	}
}

sub doc_id {
	my ($self, $doc_id) = @_;
	if (defined $doc_id) {
		$self->{doc_id} = $doc_id;
	} else {
		# TODO load from xapian
		$self->{doc_id};
	}
}

sub thread_id {
	my ($self) = @_;
	my $tid = $self->{thread};
	return $tid if defined $tid;
	$self->ensure_metadata;
	$self->{thread};
}

sub path {
	my ($self) = @_;
	my $path = $self->{path};
	return $path if defined $path;
	$self->ensure_metadata;
	$self->{path};
}

1;
