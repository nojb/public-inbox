# Copyright (C) 2016-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Emergency Maildir delivery for MDA
package PublicInbox::Emergency;
use strict;
use warnings;
use Fcntl qw(:DEFAULT SEEK_SET);
use Sys::Hostname qw(hostname);
use IO::Handle;

sub new {
	my ($class, $dir) = @_;

	-d $dir or mkdir($dir) or die "failed to mkdir($dir): $!\n";
	foreach (qw(new tmp cur)) {
		my $d = "$dir/$_";
		next if -d $d;
		-d $d or mkdir($d) or die "failed to mkdir($d): $!\n";
	}
	bless { dir => $dir, files => {}, t => 0, cnt => 0, pid => $$ }, $class;
}

sub _fn_in {
	my ($self, $dir) = @_;
	my @host = split(/\./, hostname);
	my $now = time;
	if ($self->{t} != $now) {
		$self->{t} = $now;
		$self->{cnt} = 0;
	} else {
		$self->{cnt}++;
	}

	my $f;
	do {
		$f = "$self->{dir}/$dir/$self->{t}.$$"."_$self->{cnt}.$host[0]";
		$self->{cnt}++;
	} while (-e $f);
	$f;
}

sub prepare {
	my ($self, $strref) = @_;

	die "already in transaction: $self->{tmp}" if $self->{tmp};
	my ($tmp, $fh);
	do {
		$tmp = _fn_in($self, 'tmp');
		$! = undef;
	} while (!sysopen($fh, $tmp, O_CREAT|O_EXCL|O_RDWR) && $!{EEXIST});
	print $fh $$strref or die "write failed: $!";
	$fh->flush or die "flush failed: $!";
	$fh->autoflush(1);
	$self->{fh} = $fh;
	$self->{tmp} = $tmp;
}

sub abort {
	my ($self) = @_;
	delete $self->{fh};
	my $tmp = delete $self->{tmp} or return;

	unlink($tmp) or warn "Failed to unlink $tmp: $!";
	undef;
}

sub fh {
	my ($self) = @_;
	my $fh = $self->{fh} or die "{fh} not open!\n";
	seek($fh, 0, SEEK_SET) or die "seek(fh) failed: $!";
	sysseek($fh, 0, SEEK_SET) or die "sysseek(fh) failed: $!";
	$fh;
}

sub commit {
	my ($self) = @_;
	$$ == $self->{pid} or return; # no-op in forked child

	delete $self->{fh};
	my $tmp = delete $self->{tmp} or return;
	my $new;
	do {
		$new = _fn_in($self, 'new');
	} while (!link($tmp, $new) && $!{EEXIST});
	my @sn = stat($new) or die "stat $new failed: $!";
	my @st = stat($tmp) or die "stat $tmp failed: $!";
	if ($st[0] == $sn[0] && $st[1] == $sn[1]) {
		unlink($tmp) or warn "Failed to unlink $tmp: $!";
	} else {
		warn "stat($new) and stat($tmp) differ";
	}
}

sub DESTROY { commit($_[0]) }

1;
