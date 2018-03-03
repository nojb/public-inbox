# Copyright (C) 2015-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# based on notmuch, but with no concept of folders, files or flags
#
# Wraps a document inside our Xapian search index.
package PublicInbox::SearchMsg;
use strict;
use warnings;
use Search::Xapian;
use Date::Parse qw/str2time/;
use PublicInbox::MID qw/mid_clean mid_mime/;
use PublicInbox::Address;

sub new {
	my ($class, $mime) = @_;
	my $doc = Search::Xapian::Document->new;
	$doc->add_boolean_term('T' . 'mail');

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

sub load_from_data ($$) {
	my ($self) = $_[0]; # data = $_[1]
	my ($subj, $from, $refs, $to, $cc, $blob, $mid0) = split(/\n/, $_[1]);
	$self->{subject} = $subj;
	$self->{from} = $from;
	$self->{references} = $refs;
	$self->{to} = $to;
	$self->{cc} = $cc;
	$self->{blob} = $blob;
	$self->{mid} = $mid0;
}

sub load_expand {
	my ($self) = @_;
	my $doc = $self->{doc};
	my $data = $doc->get_data or return;
	$self->{ts} = get_val($doc, &PublicInbox::Search::TS);
	utf8::decode($data);
	load_from_data($self, $data);
	$self;
}

sub load_doc {
	my ($class, $doc) = @_;
	my $data = $doc->get_data or return;
	my $ts = get_val($doc, &PublicInbox::Search::TS);
	utf8::decode($data);
	my $self = bless { doc => $doc, ts => $ts }, $class;
	load_from_data($self, $data);
	$self
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

# no strftime, that is locale-dependent and not for RFC822
my @DoW = qw(Sun Mon Tue Wed Thu Fri Sat);
my @MoY = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);

sub date ($) {
	my ($self) = @_;
	my $ts = $self->{ts};
	return unless defined $ts;
	my ($sec, $min, $hour, $mday, $mon, $year, $wday) = gmtime($ts);
	"$DoW[$wday], " . sprintf("%02d $MoY[$mon] %04d %02d:%02d:%02d +0000",
				$mday, $year+1900, $hour, $min, $sec);

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
	$self->{ts} ||= eval { str2time($self->{mime}->header('Date')) } || 0;
}

sub to_doc_data {
	my ($self, $oid, $mid0) = @_;
	my @rows = ($self->subject, $self->from, $self->references,
			$self->to, $self->cc);
	$oid = '' unless defined $oid;
	join("\n", @rows, $oid, $mid0);
}

sub references {
	my ($self) = @_;
	my $x = $self->{references};
	defined $x ? $x : '';
}

sub _get_term_val ($$$) {
	my ($self, $pfx, $re) = @_;
	my $doc = $self->{doc};
	my $end = $doc->termlist_end;
	my $i = $doc->termlist_begin;
	$i->skip_to($pfx);
	if ($i != $end) {
		my $val = $i->get_termname;
		$val =~ s/$re// and return $val;
	}
	undef;
}

sub mid ($;$) {
	my ($self, $mid) = @_;

	if (defined $mid) {
		$self->{mid} = $mid;
	} elsif (my $rv = $self->{mid}) {
		$rv;
	} else {
		$self->{mid} = _get_term_val($self, 'Q', qr/\AQ/) ||
				$self->_extract_mid;
	}
}

sub _extract_mid { mid_clean(mid_mime($_[0]->{mime})) }

sub thread_id {
	my ($self) = @_;
	my $tid = $self->{thread};
	return $tid if defined $tid;
	$self->{thread} = _get_term_val($self, 'G', qr/\AG/); # *G*roup
}

# XXX: consider removing this, we can phrase match subject
sub path {
	my ($self) = @_;
	my $path = $self->{path};
	return $path if defined $path;
	$self->{path} = _get_term_val($self, 'XPATH', qr/\AXPATH/); # path
}

sub type {
	my ($self) = @_;
	my $type = $self->{type};
	return $type if defined $type;
	$self->{type} = _get_term_val($self, 'T', qr/\AT/);
}

1;
