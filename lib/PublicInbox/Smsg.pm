# Copyright (C) 2015-2021 all contributors <meta@public-inbox.org>
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
use PublicInbox::MID qw(mids references);
use PublicInbox::Address;
use PublicInbox::MsgTime qw(msg_timestamp msg_datestamp);

sub to_doc_data {
	my ($self) = @_;
	join("\n",
		$self->{subject},
		$self->{from},
		$self->{references} // '',
		$self->{to},
		$self->{cc},
		$self->{blob},
		$self->{mid},
		$self->{bytes} // '',
		$self->{lines} // ''
	);
}

sub load_from_data ($$) {
	my ($self) = $_[0]; # data = $_[1]
	utf8::decode($_[1]);
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

sub psgi_cull ($) {
	my ($self) = @_;

	# drop NNTP-only fields which aren't relevant to PSGI results:
	# saves ~80K on a 200 item search result:
	# TODO: we may need to keep some of these for JMAP...
	my ($f) = delete @$self{qw(from tid to cc bytes lines)};
	# ghosts don't have ->{from}
	$self->{from_name} = join(', ', PublicInbox::Address::names($f // ''));
	$self;
}

sub parse_references ($$$) {
	my ($smsg, $hdr, $mids) = @_;
	my $refs = references($hdr);
	push(@$refs, @$mids) if scalar(@$mids) > 1;
	return $refs if scalar(@$refs) == 0;

	# prevent circular references here:
	my %seen = ( ($smsg->{mid} // '') => 1 );
	my @keep;
	foreach my $ref (@$refs) {
		if (length($ref) > PublicInbox::MID::MAX_MID_SIZE) {
			warn "References: <$ref> too long, ignoring\n";
			next;
		}
		$seen{$ref} //= push(@keep, $ref);
	}
	$smsg->{references} = '<'.join('> <', @keep).'>' if @keep;
	\@keep;
}

# used for v2, Import and v1 non-SQLite WWW code paths
sub populate {
	my ($self, $hdr, $sync) = @_;
	for my $f (qw(From To Cc Subject)) {
		my @all = $hdr->header($f);
		my $val = join(', ', @all);
		$val =~ tr/\r//d;
		# MIME decoding can create NULs, replace them with spaces
		# to protect git and NNTP clients
		$val =~ tr/\0\t\n/   /;

		# rare: in case headers have wide chars (not RFC2047-encoded)
		utf8::decode($val);

		# lower-case fields for read-only stuff
		$self->{lc($f)} = $val;

		# Capitalized From/Subject for git-fast-import
		next if $f eq 'To' || $f eq 'Cc';
		if (scalar(@all) > 1) {
			$val = $all[0];
			$val =~ tr/\r//d;
			$val =~ tr/\0\t\n/   /;
		}
		$self->{$f} = $val if $val ne '';
	}
	$sync //= {};
	$self->{-ds} = [ my @ds = msg_datestamp($hdr, $sync->{autime}) ];
	$self->{-ts} = [ my @ts = msg_timestamp($hdr, $sync->{cotime}) ];
	$self->{ds} //= $ds[0]; # no zone
	$self->{ts} //= $ts[0];
	$self->{mid} //= mids($hdr)->[0];
}

# no strftime, that is locale-dependent and not for RFC822
my @DoW = qw(Sun Mon Tue Wed Thu Fri Sat);
my @MoY = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);

sub date ($) { # for NNTP
	my ($self) = @_;
	my $ds = $self->{ds};
	return unless defined $ds;
	my ($sec, $min, $hour, $mday, $mon, $year, $wday) = gmtime($ds);
	"$DoW[$wday], " . sprintf("%02d $MoY[$mon] %04d %02d:%02d:%02d +0000",
				$mday, $year+1900, $hour, $min, $sec);
}

sub internaldate { # for IMAP
	my ($self) = @_;
	my ($sec, $min, $hour, $mday, $mon, $year) = gmtime($self->{ts} // 0);
	sprintf("%02d-$MoY[$mon]-%04d %02d:%02d:%02d +0000",
				$mday, $year+1900, $hour, $min, $sec);
}

our $REPLY_RE = qr/^re:\s+/i;

# TODO: see RFC 5256 sec 2.1 "Base Subject" and evaluate compatibility
# w/ existing indices...
sub subject_normalized ($) {
	my ($subj) = @_;
	$subj =~ s/\A\s+//s; # no leading space
	$subj =~ s/\s+\z//s; # no trailing space
	$subj =~ s/\s+/ /gs; # no redundant spaces
	$subj =~ s/\.+\z//; # no trailing '.'
	$subj =~ s/$REPLY_RE//igo; # remove reply prefix
	$subj;
}

# returns the number of bytes to add if given a non-CRLF arg
sub crlf_adjust ($) {
	if (index($_[0], "\r\n") < 0) {
		# common case is LF-only, every \n needs an \r;
		# so favor a cheap tr// over an expensive m//g
		$_[0] =~ tr/\n/\n/;
	} else { # count number of '\n' w/o '\r', expensive:
		scalar(my @n = ($_[0] =~ m/(?<!\r)\n/g));
	}
}

sub set_bytes { $_[0]->{bytes} = $_[2] + crlf_adjust($_[1]) }

1;
