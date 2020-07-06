# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# internal class used by PublicInbox::Git + Danga::Socket
# This parses the output pipe of "git cat-file --batch"
#
# Note: this does NOT set the non-blocking flag, we expect `git cat-file'
# to be a local process, and git won't start writing a blob until it's
# fully read.  So minimize context switching and read as much as possible
# and avoid holding a buffer in our heap any longer than it has to live.
package PublicInbox::GitAsyncCat;
use strict;
use parent qw(PublicInbox::DS Exporter);
use PublicInbox::Syscall qw(EPOLLIN EPOLLET);
our @EXPORT = qw(git_async_cat);

sub _add {
	my ($class, $git) = @_;
	$git->batch_prepare;
	my $self = bless { git => $git }, $class;
	$self->SUPER::new($git->{in}, EPOLLIN|EPOLLET);
	\undef; # this is a true ref()
}

sub event_step {
	my ($self) = @_;
	my $git = $self->{git};
	return $self->close if ($git->{in} // 0) != ($self->{sock} // 1);
	my $inflight = $git->{inflight};
	if ($inflight && @$inflight) {
		$git->cat_async_step($inflight);
		$self->requeue if @$inflight || exists $git->{cat_rbuf};
	}
}

sub git_async_cat ($$$$) {
	my ($git, $oid, $cb, $arg) = @_;
	$git->cat_async($oid, $cb, $arg);
	$git->{async_cat} //= _add(__PACKAGE__, $git);
}

1;
