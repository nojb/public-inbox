# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# internal class used by PublicInbox::Git + PublicInbox::DS
# This parses the output pipe of "git cat-file --batch"
package PublicInbox::GitAsyncCat;
use strict;
use parent qw(PublicInbox::DS Exporter);
use POSIX qw(WNOHANG);
use PublicInbox::Syscall qw(EPOLLIN EPOLLET);
our @EXPORT = qw(git_async_cat git_async_prefetch);
use PublicInbox::Git ();

our $GCF2C; # singleton PublicInbox::Gcf2Client

sub close {
	my ($self) = @_;

	if (my $gitish = delete $self->{gitish}) {
		PublicInbox::Git::cat_async_abort($gitish);
	}
	$self->SUPER::close; # PublicInbox::DS::close
}

sub event_step {
	my ($self) = @_;
	my $gitish = $self->{gitish} or return;
	return $self->close if ($gitish->{in} // 0) != ($self->{sock} // 1);
	my $inflight = $gitish->{inflight};
	if ($inflight && @$inflight) {
		$gitish->cat_async_step($inflight);

		# child death?
		if (($gitish->{in} // 0) != ($self->{sock} // 1)) {
			$self->close;
		} elsif (@$inflight || exists $gitish->{cat_rbuf}) {
			# ok, more to do, requeue for fairness
			$self->requeue;
		}
	} elsif ((my $pid = waitpid($gitish->{pid}, WNOHANG)) > 0) {
		# May happen if the child process is killed by a BOFH
		# (or segfaults)
		delete $gitish->{pid};
		warn "E: gitish $pid exited with \$?=$?\n";
		$self->close;
	}
}

sub git_async_cat ($$$$) {
	my ($git, $oid, $cb, $arg) = @_;
	my $gitish = $GCF2C //= eval {
		require PublicInbox::Gcf2;
		require PublicInbox::Gcf2Client;
		PublicInbox::Gcf2Client::new();
	} // 0; # 0: do not retry if libgit2 or Inline::C are missing
	if ($gitish) { # Gcf2 active, {inflight} may be unset due to errors
		$GCF2C->{inflight} or
			$gitish = $GCF2C = PublicInbox::Gcf2Client::new();
		$oid .= " $git->{git_dir}";
	} else {
		$gitish = $git;
	}
	$gitish->cat_async($oid, $cb, $arg);
	$gitish->{async_cat} //= do {
		# read-only end of pipe (Gcf2Client is write-only end)
		my $self = bless { gitish => $gitish }, __PACKAGE__;
		$gitish->{in}->blocking(0);
		$self->SUPER::new($gitish->{in}, EPOLLIN|EPOLLET);
		\undef; # this is a true ref()
	};
}

# this is safe to call inside $cb, but not guaranteed to enqueue
# returns true if successful, undef if not.
sub git_async_prefetch {
	my ($git, $oid, $cb, $arg) = @_;
	if ($GCF2C) {
		if ($GCF2C->{async_cat} && !$GCF2C->{wbuf}) {
			$oid .= " $git->{git_dir}";
			return $GCF2C->cat_async($oid, $cb, $arg);
		}
	} elsif ($git->{async_cat} && (my $inflight = $git->{inflight})) {
		# we could use MAX_INFLIGHT here w/o the halving,
		# but lets not allow one client to monopolize a git process
		if (@$inflight < int(PublicInbox::Git::MAX_INFLIGHT/2)) {
			print { $git->{out} } $oid, "\n" or
						$git->fail("write error: $!");
			return push(@$inflight, $oid, $cb, $arg);
		}
	}
	undef;
}

1;
