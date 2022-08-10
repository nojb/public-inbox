# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# RFC 8054 NNTP COMPRESS DEFLATE implementation
# RFC 4978 IMAP COMPRESS=DEFLATE extension
#
# RSS usage for 10K idle-but-did-something NNTP clients on 64-bit:
#   TLS + DEFLATE[a] :  1.8 GB  (MemLevel=9, 1.2 GB with MemLevel=8)
#   TLS + DEFLATE[b] :  ~300MB
#   TLS only         :  <200MB
#   plain            :   <50MB
#
# [a] - initial implementation using per-client Deflate contexts and buffer
#
# [b] - memory-optimized implementation using a global deflate context.
#       It's less efficient in terms of compression, but way more
#       efficient in terms of server memory usage.
package PublicInbox::DSdeflate;
use strict;
use v5.10.1;
use Compress::Raw::Zlib;

my %IN_OPT = (
	-Bufsize => 1024,
	-WindowBits => -15, # RFC 1951
	-AppendOutput => 1,
);

# global deflate context and buffer
my ($zout, $zbuf);
{
	my $err;
	$zbuf = \(my $initial = ''); # replaced by $next in dflush/write
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
	my ($class, $self) = @_;
	my ($in, $err) = Compress::Raw::Zlib::Inflate->new(%IN_OPT);
	if ($err != Z_OK) {
		warn("Inflate->new failed: $err\n");
		return;
	}
	bless $self, $class;
	$self->{zin} = $in;
}

# overrides PublicInbox::DS::compressed
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

sub dflush ($) {
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
