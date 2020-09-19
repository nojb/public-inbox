# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# internal class used by PublicInbox::Git + PublicInbox::DS
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

sub event_step {
	my ($self) = @_;
	my $gitish = $self->{gitish};
	return $self->close if ($gitish->{in} // 0) != ($self->{sock} // 1);
	my $inflight = $gitish->{inflight};
	if ($inflight && @$inflight) {
		$gitish->cat_async_step($inflight);
		$self->requeue if @$inflight || exists $gitish->{cat_rbuf};
	}
}

sub git_async_cat ($$$$) {
	my ($git, $oid, $cb, $arg) = @_;
	my $gitish = $git->{gcf2c}; # PublicInbox::Gcf2Client
	if ($gitish) {
		$oid .= " $git->{git_dir}";
	} else {
		$gitish = $git;
	}
	$gitish->cat_async($oid, $cb, $arg);
	$gitish->{async_cat} //= do {
		my $self = bless { gitish => $gitish }, __PACKAGE__;
		$self->SUPER::new($gitish->{in}, EPOLLIN|EPOLLET);
		\undef; # this is a true ref()
	};
}

1;
