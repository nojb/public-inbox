# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# temporary queue for public-inbox-index to support multi-Message-ID
# messages on mirrors of v2 inboxes
package PublicInbox::MultiMidQueue;
use strict;
use SDBM_File; # part of Perl standard library
use Fcntl qw(O_RDWR O_CREAT);
use File::Temp 0.19 (); # 0.19 for ->newdir
my %e = (
	freebsd => 0x100000,
	linux => 0x80000,
	netbsd => 0x400000,
	openbsd => 0x10000,
);
my $O_CLOEXEC = $e{$^O} // 0;

sub new {
	my ($class) = @_;
	my $tmpdir = File::Temp->newdir('multi-mid-q-XXXXXX', TMPDIR => 1);
	my $base = $tmpdir->dirname . '/q';
	my %sdbm;
	my $flags = O_RDWR|O_CREAT;
	if (!tie(%sdbm, 'SDBM_File', $base, $flags|$O_CLOEXEC, 0600)) {
		if (!tie(%sdbm, 'SDBM_File', $base, $flags, 0600)) {
			die "could not tie ($base): $!";
		}
		$O_CLOEXEC = 0;
	}

	bless {
		cur => 1,
		min => 1,
		max => 0,
		sdbm => \%sdbm,
		tmpdir => $tmpdir,
	}, $class;
}

sub set_oid {
	my ($self, $i, $oid, $v2w) = @_;
	$self->{max} = $i if $i > $self->{max};
	$self->{min} = $i if $i < $self->{min};
	$self->{sdbm}->{$i} = "$oid\t$v2w->{autime}\t$v2w->{cotime}";
}

sub get_oid {
	my ($self, $i, $v2w) = @_;
	my $rec = $self->{sdbm}->{$i} or return;
	my ($oid, $autime, $cotime) = split(/\t/, $rec);
	$v2w->{autime} = $autime;
	$v2w->{cotime} = $cotime;
	$oid
}

sub push_oid {
	my ($self, $oid, $v2w) = @_;
	set_oid($self, $self->{cur}++, $oid, $v2w);
}

1;
