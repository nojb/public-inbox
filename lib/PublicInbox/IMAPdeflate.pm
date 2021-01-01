# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# TODO: reduce duplication from PublicInbox::NNTPdeflate

# RFC 4978
package PublicInbox::IMAPdeflate;
use strict;
use warnings;
use 5.010_001;
use base qw(PublicInbox::IMAP);
use Compress::Raw::Zlib;

my %IN_OPT = (
	-Bufsize => 1024,
	-WindowBits => -15, # RFC 1951
	-AppendOutput => 1,
);

# global deflate context and buffer
my $zbuf = \(my $buf = '');
my $zout;
{
	my $err;
	($zout, $err) = Compress::Raw::Zlib::Deflate->new(
		# nnrpd (INN) and Compress::Raw::Zlib favor MemLevel=9,
		# the zlib C library and git use MemLevel=8 as the default
		# -MemLevel => 9,
		-Bufsize => 65536, # same as nnrpd
		-WindowBits => -15, # RFC 1951
		-AppendOutput => 1,
	);
	$err == Z_OK or die "Failed to initialize zlib deflate stream: $err";
}

sub enable {
	my ($class, $self, $tag) = @_;
	my ($in, $err) = Compress::Raw::Zlib::Inflate->new(%IN_OPT);
	if ($err != Z_OK) {
		$self->err("Inflate->new failed: $err");
		$self->write(\"$tag BAD failed to activate compression\r\n");
		return;
	}
	$self->write(\"$tag OK DEFLATE active\r\n");
	bless $self, $class;
	$self->{zin} = $in;
}

# overrides PublicInbox::NNTP::compressed
sub compressed { 1 }

sub do_read ($$$$) {
	my ($self, $rbuf, $len, $off) = @_;

	my $zin = $self->{zin} or return; # closed
	my $doff;
	my $dbuf = delete($self->{dbuf}) // '';
	$doff = length($dbuf);
	my $r = PublicInbox::DS::do_read($self, \$dbuf, $len, $doff) or return;

	# Workaround inflate bug appending to OOK scalars:
	# <https://rt.cpan.org/Ticket/Display.html?id=132734>
	# We only have $off if the client is pipelining, and pipelining
	# is where our substr() OOK optimization in event_step makes sense.
	if ($off) {
		my $copy = $$rbuf;
		undef $$rbuf;
		$$rbuf = $copy;
	}

	# assert(length($$rbuf) == $off) as far as NNTP.pm is concerned
	# -ConsumeInput is true, so $dbuf is automatically emptied
	my $err = $zin->inflate($dbuf, $rbuf);
	if ($err == Z_OK) {
		$self->{dbuf} = $dbuf if $dbuf ne '';
		$r = length($$rbuf) and return $r;
		# nothing ready, yet, get more, later
		$self->requeue;
	} else {
		delete $self->{zin};
		$self->close;
	}
	0;
}

# override PublicInbox::DS::msg_more
sub msg_more ($$) {
	my $self = $_[0];

	# $_[1] may be a reference or not for ->deflate
	my $err = $zout->deflate($_[1], $zbuf);
	$err == Z_OK or die "->deflate failed $err";
	1;
}

sub zflush ($) {
	my ($self) = @_;

	my $deflated = $zbuf;
	$zbuf = \(my $next = '');

	my $err = $zout->flush($deflated, Z_FULL_FLUSH);
	$err == Z_OK or die "->flush failed $err";

	# We can still let the lower socket layer do buffering:
	PublicInbox::DS::msg_more($self, $$deflated);
}

# compatible with PublicInbox::DS::write, so $_[1] may be a reference or not
sub write ($$) {
	my $self = $_[0];
	return PublicInbox::DS::write($self, $_[1]) if ref($_[1]) eq 'CODE';

	my $deflated = $zbuf;
	$zbuf = \(my $next = '');

	# $_[1] may be a reference or not for ->deflate
	my $err = $zout->deflate($_[1], $deflated);
	$err == Z_OK or die "->deflate failed $err";
	$err = $zout->flush($deflated, Z_FULL_FLUSH);
	$err == Z_OK or die "->flush failed $err";

	# We can still let the socket layer do buffering:
	PublicInbox::DS::write($self, $deflated);
}

1;
