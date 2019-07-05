# Copyright (C) 2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# RFC 8054 NNTP COMPRESS DEFLATE implementation
# Warning, enabling compression for C10K NNTP clients is rather
# expensive in terms of memory use.
#
# RSS usage for 10K idle-but-did-something NNTP clients on 64-bit:
#   TLS + DEFLATE :  1.8 GB  (MemLevel=9, 1.2 GB with MemLevel=8)
#   TLS only      :  <200MB
#   plain         :   <50MB
package PublicInbox::NNTPdeflate;
use strict;
use warnings;
use 5.010_001;
use base qw(PublicInbox::NNTP);
use Compress::Raw::Zlib;
use Hash::Util qw(unlock_hash); # dependency of fields for perl 5.10+, anyways

my %IN_OPT = (
	-Bufsize => PublicInbox::NNTP::LINE_MAX,
	-WindowBits => -15, # RFC 1951
	-AppendOutput => 1,
);

my %OUT_OPT = (
	# nnrpd (INN) and Compress::Raw::Zlib favor MemLevel=9,
	# but the zlib C library and git use MemLevel=8
	# as the default.  Using 8 drops our memory use with 10K
	# TLS clients from 1.8 GB to 1.2 GB, but...
	# FIXME: sometimes clients fail with 8, so we use 9
	# -MemLevel => 9,

	# needs more testing, nothing obviously different in terms of memory
	-Bufsize => 65536,

	-WindowBits => -15, # RFC 1951
	-AppendOutput => 1,
);

sub enable {
	my ($class, $self) = @_;
	unlock_hash(%$self);
	bless $self, $class;
	$self->{zin} = [ Compress::Raw::Zlib::Inflate->new(%IN_OPT), '' ];
	$self->{zout} = [ Compress::Raw::Zlib::Deflate->new(%OUT_OPT), '' ];
}

# overrides PublicInbox::NNTP::compressed
sub compressed { 1 }

# SUPER is PublicInbox::DS::do_read, so $_[1] may be a reference or not
sub do_read ($$$$) {
	my ($self, $rbuf, $len, $off) = @_;

	my $zin = $self->{zin} or return; # closed
	my $deflated = \($zin->[1]);
	my $r = $self->SUPER::do_read($deflated, $len) or return;

	# assert(length($$rbuf) == $off) as far as NNTP.pm is concerned
	# -ConsumeInput is true, so $deflated is automatically emptied
	my $err = $zin->[0]->inflate($deflated, $rbuf);
	if ($err == Z_OK) {
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
	my $zout = $self->{zout};

	# $_[1] may be a reference or not for ->deflate
	my $err = $zout->[0]->deflate($_[1], $zout->[1]);
	$err == Z_OK or die "->deflate failed $err";
	1;
}

# SUPER is PublicInbox::DS::write, so $_[1] may be a reference or not
sub write ($$) {
	my $self = $_[0];
	return $self->SUPER::write($_[1]) if ref($_[1]) eq 'CODE';
	my $zout = $self->{zout};
	my $deflated = pop @$zout;

	# $_[1] may be a reference or not for ->deflate
	my $err = $zout->[0]->deflate($_[1], $deflated);
	$err == Z_OK or die "->deflate failed $err";
	$err = $zout->[0]->flush($deflated, Z_PARTIAL_FLUSH);
	$err == Z_OK or die "->flush failed $err";

	# PublicInbox::DS::write puts partial writes into another buffer,
	# so we can prepare the next deflate buffer:
	$zout->[1] = '';
	$self->SUPER::write(\$deflated);
}

1;
