# Copyright (C) 2015, all contributors <meta@public-inbox.org>
# License: GPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
# based on notmuch, but with no concept of folders, files or flags
package PublicInbox::SearchMsg;
use strict;
use warnings;
use Search::Xapian;
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

sub mid {
	my ($self, $mid) = @_;

	if (defined $mid) {
	    $self->{mid} = $mid;
	} else {
	    $self->{mid} ||= $self->_extract_mid;
	}
}

sub _extract_mid {
	my ($self) = @_;

	my $mid = $self->mime->header('Message-ID');
	if ($mid && $mid =~ /<([^>]+)>/) {
		return $1;
	}
	return $mid;
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
