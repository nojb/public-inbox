# Copyright (C) 2016-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# a tied handle for auto reaping of children tied to a pipe, see perltie(1)
package PublicInbox::ProcessPipe;
use strict;
use v5.10.1;
use PublicInbox::DS qw(dwaitpid);

sub TIEHANDLE {
	my ($class, $pid, $fh, $cb, $arg) = @_;
	bless { pid => $pid, fh => $fh, cb => $cb, arg => $arg }, $class;
}

sub READ { read($_[0]->{fh}, $_[1], $_[2], $_[3] || 0) }

sub READLINE { readline($_[0]->{fh}) }

sub WRITE {
	use bytes qw(length);
	syswrite($_[0]->{fh}, $_[1], $_[2] // length($_[1]), $_[3] // 0);
}

sub PRINT {
	my $self = shift;
	print { $self->{fh} } @_;
}

sub adjust_ret { # dwaitpid callback
	my ($retref, $pid) = @_;
	$$retref = '' if $?
}

sub CLOSE {
	my $fh = delete($_[0]->{fh});
	my $ret = defined $fh ? close($fh) : '';
	my ($pid, $cb, $arg) = delete @{$_[0]}{qw(pid cb arg)};
	if (defined $pid) {
		unless ($cb) {
			$cb = \&adjust_ret;
			$arg = \$ret;
		}
		dwaitpid $pid, $cb, $arg;
	}
	$ret;
}

sub FILENO { fileno($_[0]->{fh}) }

sub DESTROY {
	CLOSE(@_);
	undef;
}

sub pid { $_[0]->{pid} }

1;
