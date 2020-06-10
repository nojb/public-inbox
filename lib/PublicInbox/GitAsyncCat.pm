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
use fields qw(git);
use PublicInbox::Syscall qw(EPOLLIN EPOLLET);
our @EXPORT = qw(git_async_msg);

sub new {
	my ($class, $git) = @_;
	my $self = fields::new($class);
	$git->batch_prepare;
	$self->SUPER::new($git->{in}, EPOLLIN|EPOLLET);
	$self->{git} = $git;
	$self;
}

sub event_step {
	my ($self) = @_;
	my $git = $self->{git} or return; # ->close-ed
	my $inflight = $git->{inflight};
	if (@$inflight) {
		$git->cat_async_step($inflight);
		$self->requeue if @$inflight || length(${$git->{'--batch'}});
	}
}

sub close {
	my ($self) = @_;
	delete $self->{git};
	$self->SUPER::close; # PublicInbox::DS::close
}

sub git_async_msg ($$$$) {
	my ($ibx, $smsg, $cb, $arg) = @_;
	$ibx->git->cat_async($smsg->{blob}, $cb, $arg);
	$ibx->{async_cat} //= new(__PACKAGE__, $ibx->{git});
}

1;
