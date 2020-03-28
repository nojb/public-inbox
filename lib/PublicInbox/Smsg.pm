# Copyright (C) 2015-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# A small/skeleton/slim representation of a message.

# This used to be "SearchMsg", but we split out overview
# indexing into over.sqlite3 so it's not just "search".  There
# may be many of these objects loaded in memory at once for
# large threads in our WWW UI and the NNTP range responses.
package PublicInbox::Smsg;
use strict;
use warnings;
use base qw(Exporter);
our @EXPORT_OK = qw(subject_normalized);
use PublicInbox::MID qw/mid_clean mid_mime/;
use PublicInbox::Address;
use PublicInbox::MsgTime qw(msg_timestamp msg_datestamp);
use Time::Local qw(timegm);

sub new {
	my ($class, $mime) = @_;
	bless { mime => $mime }, $class;
}

sub wrap {
	my ($class, $mid) = @_;
	bless { mid => $mid }, $class;
}

sub get_val ($$) {
	my ($doc, $col) = @_;
	# sortable_unserialise is defined by PublicInbox::Search::load_xapian()
	sortable_unserialise($doc->get_value($col));
}

sub to_doc_data {
	my ($self) = @_;
	join("\n",
		$self->subject,
		$self->from,
		$self->references,
		$self->to,
		$self->cc,
		$self->{blob},
		$self->{mid},
		$self->{bytes} // '',
		$self->{lines} // ''
	);
}

sub load_from_data ($$) {
	my ($self) = $_[0]; # data = $_[1]
	(
		$self->{subject},
		$self->{from},
		$self->{references},

		# To: and Cc: are stored to optimize HDR/XHDR in NNTP since
		# some NNTP clients will use that for message displays.
		# NNTP only, and only stored in Over(view), not Xapian
		$self->{to},
		$self->{cc},

		$self->{blob},
		$self->{mid},

		# NNTP only
		$self->{bytes},
		$self->{lines}
	) = split(/\n/, $_[1]);
}

sub load_expand {
	my ($self, $doc) = @_;
	my $data = $doc->get_data or return;
	$self->{ts} = get_val($doc, PublicInbox::Search::TS());
	my $dt = get_val($doc, PublicInbox::Search::DT());
	my ($yyyy, $mon, $dd, $hh, $mm, $ss) = unpack('A4A2A2A2A2A2', $dt);
	$self->{ds} = timegm($ss, $mm, $hh, $dd, $mon - 1, $yyyy);
	utf8::decode($data);
	load_from_data($self, $data);
	$self;
}

sub psgi_cull ($) {
	my ($self) = @_;
	from_name($self); # fill in {from_name} so we can delete {from}

	# drop NNTP-only fields which aren't relevant to PSGI results:
	# saves ~80K on a 200 item search result:
	delete @$self{qw(from ts to cc bytes lines)};
	$self;
}

# Only called by PSGI interface, not NNTP
sub from_mitem {
	my ($mitem, $srch) = @_;
	return $srch->retry_reopen(\&from_mitem, $mitem) if $srch;
	my $self = bless {}, __PACKAGE__;
	psgi_cull(load_expand($self, $mitem->get_document));
}

# :bytes and :lines metadata in RFC 3977
sub bytes ($) { $_[0]->{bytes} }
sub lines ($) { $_[0]->{lines} }

sub __hdr ($$) {
	my ($self, $field) = @_;
	my $val = $self->{$field};
	return $val if defined $val;

	my $mime = $self->{mime} or return;
	my @raw = $mime->header($field);
	$val = join(', ', @raw);
	$val =~ tr/\t\n/  /;
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
	my $ds = $self->{ds};
	return unless defined $ds;
	my ($sec, $min, $hour, $mday, $mon, $year, $wday) = gmtime($ds);
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
	$self->{ts} ||= eval { msg_timestamp($self->{mime}->header_obj) } || 0;
}

sub ds {
	my ($self) = @_;
	$self->{ds} ||= eval { msg_datestamp($self->{mime}->header_obj); } || 0;
}

sub references {
	my ($self) = @_;
	my $x = $self->{references};
	defined $x ? $x : '';
}

sub mid ($;$) {
	my ($self, $mid) = @_;

	if (defined $mid) {
		$self->{mid} = $mid;
	} elsif (defined(my $rv = $self->{mid})) {
		$rv;
	} else {
		die "NO {mime} for mid\n" unless $self->{mime};
		$self->_extract_mid; # v1 w/o Xapian
	}
}

sub _extract_mid { mid_clean(mid_mime($_[0]->{mime})) }

our $REPLY_RE = qr/^re:\s+/i;

sub subject_normalized ($) {
	my ($subj) = @_;
	$subj =~ s/\A\s+//s; # no leading space
	$subj =~ s/\s+\z//s; # no trailing space
	$subj =~ s/\s+/ /gs; # no redundant spaces
	$subj =~ s/\.+\z//; # no trailing '.'
	$subj =~ s/$REPLY_RE//igo; # remove reply prefix
	$subj;
}

1;