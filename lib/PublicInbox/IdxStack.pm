# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# temporary stack for public-inbox-index
package PublicInbox::IdxStack;
use v5.10.1;
use strict;
use Fcntl qw(:seek);
use constant PACK_FMT => eval { pack('Q', 1) } ? 'A1QQH*H*' : 'A1IIH*H*';

# start off in write-only mode
sub new {
	open(my $io, '+>', undef) or die "open: $!";
	# latest_cmt is still useful when the newest revision is a `d'(elete),
	# otherwise we favor $sync->{latest_cmt} for checkpoints and {quit}
	bless { wr => $io, latest_cmt => $_[1] }, __PACKAGE__
}

# file_char = [d|m]
sub push_rec {
	my ($self, $file_char, $at, $ct, $blob_oid, $cmt_oid) = @_;
	my $rec = pack(PACK_FMT, $file_char, $at, $ct, $blob_oid, $cmt_oid);
	$self->{unpack_fmt} // do {
		my $len = length($cmt_oid);
		my $fmt = PACK_FMT;
		$fmt =~ s/H\*/H$len/g;
		$self->{rec_size} = length($rec);
		$self->{unpack_fmt} = $fmt;
	};
	print { $self->{wr} } $rec or die "print: $!";
	$self->{tot_size} += length($rec);
}

sub num_records {
	my ($self) = @_;
	$self->{rec_size} ? $self->{tot_size} / $self->{rec_size} : 0;
}

# switch into read-only mode and returns self
sub read_prepare {
	my ($self) = @_;
	my $io = $self->{rd} = delete($self->{wr});
	$io->flush or die "flush: $!";
	$self;
}

sub pop_rec {
	my ($self) = @_;
	my $sz = $self->{rec_size} or return;
	my $rec_pos = $self->{tot_size} -= $sz;
	return if $rec_pos < 0;
	my $io = $self->{rd};
	seek($io, $rec_pos, SEEK_SET) or die "seek: $!";
	my $r = read($io, my $buf, $sz);
	defined($r) or die "read: $!";
	$r == $sz or die "read($r != $sz)";
	unpack($self->{unpack_fmt}, $buf);
}

1;
