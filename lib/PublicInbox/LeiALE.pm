# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# All Locals Ever: track lei/store + externals ever used as
# long as they're on an accessible FS.  Includes "lei q" --include
# and --only targets that haven't been through "lei add-external".
# Typically: ~/.cache/lei/all_locals_ever.git
package PublicInbox::LeiALE;
use strict;
use v5.10.1;
use parent qw(PublicInbox::LeiSearch PublicInbox::Lock);
use PublicInbox::Git;
use PublicInbox::Import;
use PublicInbox::LeiXSearch;
use Fcntl qw(SEEK_SET);

sub _new {
	my ($d) = @_;
	PublicInbox::Import::init_bare($d, 'ale');
	bless {
		git => PublicInbox::Git->new($d),
		lock_path => "$d/lei_ale.state", # dual-duty lock + state
		ibxish => [], # Inbox and ExtSearch (and LeiSearch) objects
	}, __PACKAGE__
}

sub new {
	my ($self, $lei) = @_;
	ref($self) or $self = _new($lei->cache_dir . '/all_locals_ever.git');
	my $lxs = PublicInbox::LeiXSearch->new;
	$lxs->prepare_external($lei->_lei_store(1)->search);
	for my $loc ($lei->externals_each) { # locals only
		$lxs->prepare_external($loc) if -d $loc;
	}
	$self->refresh_externals($lxs);
	$self;
}

sub over {} # undef for xoids_for

sub overs_all { # for xoids_for (called only in lei workers?)
	my ($self) = @_;
	my $pid = $$;
	if (($self->{owner_pid} // $pid) != $pid) {
		delete($_->{over}) for @{$self->{ibxish}};
	}
	$self->{owner_pid} = $pid;
	grep(defined, map { $_->over } @{$self->{ibxish}});
}

sub refresh_externals {
	my ($self, $lxs) = @_;
	$self->git->cleanup;
	my $lk = $self->lock_for_scope;
	my $cur_lxs = ref($lxs)->new;
	my $orig = do {
		local $/;
		readline($self->{lockfh}) //
				die "readline($self->{lock_path}): $!";
	};
	my $new = '';
	my $old = '';
	my $gone = 0;
	my %seen_ibxish; # $dir => any-defined value
	for my $dir (split(/\n/, $orig)) {
		if (-d $dir && -r _ && $cur_lxs->prepare_external($dir)) {
			$seen_ibxish{$dir} //= length($old .= "$dir\n");
		} else {
			++$gone;
		}
	}
	my @ibxish = $cur_lxs->locals;
	for my $x ($lxs->locals) {
		my $d = File::Spec->canonpath($x->{inboxdir} // $x->{topdir});
		$seen_ibxish{$d} //= do {
			$new .= "$d\n";
			push @ibxish, $x;
		};
	}
	if ($new ne '' || $gone) {
		$self->{lockfh}->autoflush(1);
		if ($gone) {
			seek($self->{lockfh}, 0, SEEK_SET) or die "seek: $!";
			truncate($self->{lockfh}, 0) or die "truncate: $!";
		} else {
			$old = '';
		}
		print { $self->{lockfh} } $old, $new or die "print: $!";
	}
	$new = $old = '';
	my $f = $self->git->{git_dir}.'/objects/info/alternates';
	if (open my $fh, '<', $f) {
		local $/;
		$old = <$fh> // die "readline($f): $!";
	}
	for my $x (@ibxish) {
		$new .= File::Spec->canonpath($x->git->{git_dir})."/objects\n";
	}
	$self->{ibxish} = \@ibxish;
	return if $old eq $new;

	# this needs to be atomic since child processes may start
	# git-cat-file at any time
	my $tmp = "$f.$$.tmp";
	open my $fh, '>', $tmp or die "open($tmp): $!";
	print $fh $new or die "print($tmp): $!";
	close $fh or die "close($tmp): $!";
	rename($tmp, $f) or die "rename($tmp, $f): $!";
}

1;
