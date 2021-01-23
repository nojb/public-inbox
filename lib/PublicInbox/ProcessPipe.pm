# Copyright (C) 2016-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# a tied handle for auto reaping of children tied to a pipe, see perltie(1)
package PublicInbox::ProcessPipe;
use strict;
use v5.10.1;
use Carp qw(carp);

sub TIEHANDLE {
	my ($class, $pid, $fh, $cb, $arg) = @_;
	bless { pid => $pid, fh => $fh, ppid => $$, cb => $cb, arg => $arg },
		$class;
}

sub BINMODE { binmode(shift->{fh}) } # for IO::Uncompress::Gunzip

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

sub FILENO { fileno($_[0]->{fh}) }

sub _close ($;$) {
	my ($self, $wait) = @_;
	my $fh = delete $self->{fh};
	my $ret = defined($fh) ? close($fh) : '';
	my ($pid, $cb, $arg) = delete @$self{qw(pid cb arg)};
	return $ret unless defined($pid) && $self->{ppid} == $$;
	if ($wait) { # caller cares about the exit status:
		my $wp = waitpid($pid, 0);
		if ($wp == $pid) {
			$ret = '' if $?;
			if ($cb) {
				eval { $cb->($arg, $pid) };
				carp "E: cb(arg, $pid): $@" if $@;
			}
		} else {
			carp "waitpid($pid, 0) = $wp, \$!=$!, \$?=$?";
		}
	} else { # caller just undef-ed it, let event loop deal with it
		require PublicInbox::DS;
		PublicInbox::DS::dwaitpid($pid, $cb, $arg);
	}
	$ret;
}

# if caller uses close(), assume they want to check $? immediately so
# we'll waitpid() synchronously.  n.b. wantarray doesn't seem to
# propagate `undef' down to tied methods, otherwise I'd rely on that.
sub CLOSE { _close($_[0], 1) }

# if relying on DESTROY, assume the caller doesn't care about $? and
# we can let the event loop call waitpid() whenever it gets SIGCHLD
sub DESTROY {
	_close($_[0]);
	undef;
}

1;
