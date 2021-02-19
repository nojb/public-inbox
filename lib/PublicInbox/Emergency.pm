# Copyright (C) 2016-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Emergency Maildir delivery for MDA
package PublicInbox::Emergency;
use strict;
use v5.10.1;
use Fcntl qw(:DEFAULT SEEK_SET);
use Sys::Hostname qw(hostname);
use IO::Handle; # ->flush
use Errno qw(EEXIST);

sub new {
	my ($class, $dir) = @_;

	foreach (qw(new tmp cur)) {
		my $d = "$dir/$_";
		next if -d $d;
		require File::Path;
		if (!File::Path::mkpath($d) && !-d $d) {
			die "failed to mkpath($d): $!\n";
		}
	}
	bless { dir => $dir, t => 0 }, $class;
}

sub _fn_in {
	my ($self, $pid, $dir) = @_;
	my $host = $self->{short_host} //= (split(/\./, hostname))[0];
	my $now = time;
	my $n;
	if ($self->{t} != $now) {
		$self->{t} = $now;
		$n = $self->{cnt} = 0;
	} else {
		$n = ++$self->{cnt};
	}
	"$self->{dir}/$dir/$self->{t}.$pid"."_$n.$host";
}

sub prepare {
	my ($self, $strref) = @_;
	my $pid = $$;
	my $tmp_key = "tmp.$pid";
	die "already in transaction: $self->{$tmp_key}" if $self->{$tmp_key};
	my ($tmp, $fh);
	do {
		$tmp = _fn_in($self, $pid, 'tmp');
		$! = undef;
	} while (!sysopen($fh, $tmp, O_CREAT|O_EXCL|O_RDWR) and $! == EEXIST);
	print $fh $$strref or die "write failed: $!";
	$fh->flush or die "flush failed: $!";
	$self->{fh} = $fh;
	$self->{$tmp_key} = $tmp;
}

sub abort {
	my ($self) = @_;
	delete $self->{fh};
	my $tmp = delete $self->{"tmp.$$"} or return;
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
	my $pid = $$;
	my $tmp = delete $self->{"tmp.$pid"} or return;
	delete $self->{fh};
	my ($new, $ok);
	do {
		$new = _fn_in($self, $pid, 'new');
	} while (!($ok = link($tmp, $new)) && $! == EEXIST);
	die "link($tmp, $new): $!" unless $ok;
	unlink($tmp) or warn "Failed to unlink $tmp: $!";
}

sub DESTROY { commit($_[0]) }

1;
