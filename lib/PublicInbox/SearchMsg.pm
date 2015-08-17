# Copyright (C) 2015, all contributors <meta@public-inbox.org>
# License: GPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
# based on notmuch, but with no concept of folders, files or flags
package PublicInbox::SearchMsg;
use strict;
use warnings;
use Search::Xapian;
use Email::Address qw//;
use Email::Simple qw//;
use POSIX qw//;
use Date::Parse qw/str2time/;
use PublicInbox::MID qw/mid_clean mid_compressed/;
use Encode qw/find_encoding/;
my $enc_utf8 = find_encoding('UTF-8');
our $PFX2TERM_RE = undef;

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

sub load_doc {
	my ($class, $doc) = @_;
	my $data = $doc->get_data;
	$data = $enc_utf8->decode($data);
	my ($mid, $subj, $from, $date) = split(/\n/, $data);
	bless {
		doc => $doc,
		mid => $mid,
		subject => $subj,
		date => $date,
		from_name => $from,
	}, $class;
}

sub subject {
	my ($self) = @_;
	my $subj = $self->{subject};
	return $subj if defined $subj;
	$subj = $self->{mime}->header('Subject');
	$subj = '' unless defined $subj;
	$subj =~ tr/\n/ /;
	$self->{subject} = $subj;
}

sub from {
	my ($self) = @_;
	my $from = $self->mime->header('From') || '';
	my @from;

	if ($from) {
		$from =~ tr/\n/ /;
		@from = Email::Address->parse($from);
		$self->{from} = $from[0];
		$from = $from[0]->name;
	}
	$self->{from_name} = $from;
	$self->{from};
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
	my $ts = $self->{ts};
	return $ts if $ts;
	$self->{date} = undef;
	$self->date;
	$self->{ts};
}

sub date {
	my ($self) = @_;
	my $date = $self->{date};
	return $date if $date;
	my $ts = eval { str2time($self->mime->header('Date')) } || 0;
	$self->{ts} = $ts;
	$self->{date} = POSIX::strftime('%Y-%m-%d %H:%M', gmtime($ts));
}

sub to_doc_data {
	my ($self) = @_;

	$self->mid . "\n" .
	$self->subject . "\n" .
	$self->from_name . "\n".
	$self->date;
}

sub ensure_metadata {
	my ($self) = @_;
	my $doc = $self->{doc};
	my $i = $doc->termlist_begin;
	my $end = $doc->termlist_end;

	unless (defined $PFX2TERM_RE) {
		my $or = join('|', keys %PublicInbox::Search::PFX2TERM_RMAP);
		$PFX2TERM_RE = qr/\A($or)/;
	}

	for (; $i != $end; $i->inc) {
		my $val = $i->get_termname;

		if ($val =~ s/$PFX2TERM_RE//o) {
			my $field = $PublicInbox::Search::PFX2TERM_RMAP{$1};
			if ($field eq 'references') {
				my $refs = $self->{references} ||= [];
				push @$refs, $val;
			} else {
				$self->{$field} = $val;
			}
		}
	}
}

# for threading only
sub mini_mime {
	my ($self) = @_;
	$self->ensure_metadata;
	my @h = (
		Subject => $self->subject,
		'X-PI-From' => $self->from_name,
		'X-PI-Date' => $self->date,
		'X-PI-TS' => $self->ts,
		'Message-ID' => "<$self->{mid}>",
	);
	if (my $refs = $self->{references}) {
		push @h, References => '<' . join('> <', @$refs) . '>';
	}
	if (my $irt = $self->{inreplyto}) {
		push @h, 'In-Reply-To' => "<$irt>";
	}

	Email::MIME->create(header_str => \@h);
}

sub mid {
	my ($self, $mid) = @_;

	if (defined $mid) {
		$self->{mid} = $mid;
	} else {
		$self->ensure_metadata; # needed for ghosts
		$self->{mid} ||= $self->_extract_mid;
	}
}

sub _extract_mid {
	my ($self) = @_;

	my $mid = $self->mime->header('Message-ID');
	$mid ? mid_compressed(mid_clean($mid)) : $mid;
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
