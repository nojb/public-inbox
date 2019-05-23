# Copyright (C) 2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# common stuff for administrative command-line tools
# Unstable internal API
package PublicInbox::Admin;
use strict;
use warnings;
use Cwd 'abs_path';
use base qw(Exporter);
our @EXPORT_OK = qw(resolve_repo_dir);

sub resolve_repo_dir {
	my ($cd, $ver) = @_;
	my $prefix = defined $cd ? $cd : './';
	if (-d $prefix && -f "$prefix/inbox.lock") { # v2
		$$ver = 2 if $ver;
		return abs_path($prefix);
	}

	my @cmd = qw(git rev-parse --git-dir);
	my $cmd = join(' ', @cmd);
	my $pid = open my $fh, '-|';
	defined $pid or die "forking $cmd failed: $!\n";
	if ($pid == 0) {
		if (defined $cd) {
			chdir $cd or die "chdir $cd failed: $!\n";
		}
		exec @cmd;
		die "Failed to exec $cmd: $!\n";
	} else {
		my $dir = eval {
			local $/;
			<$fh>;
		};
		close $fh or die "error in $cmd: $!\n";
		chomp $dir;
		$$ver = 1 if $ver;
		return abs_path($cd) if ($dir eq '.' && defined $cd);
		abs_path($dir);
	}
}

sub resolve_inboxes {
	my ($argv, $warn_on_unconfigured) = @_;
	require PublicInbox::Config;
	require PublicInbox::Inbox;

	my @ibxs = map { resolve_repo_dir($_) } @$argv;
	push(@ibxs, resolve_repo_dir()) unless @ibxs;

	my %dir2ibx;
	if (my $config = eval { PublicInbox::Config->new }) {
		$config->each_inbox(sub {
			my ($ibx) = @_;
			$dir2ibx{abs_path($ibx->{mainrepo})} = $ibx;
		});
	} elsif ($warn_on_unconfigured) {
		# do we really care about this?  It's annoying...
		warn $warn_on_unconfigured, "\n";
	}
	for my $i (0..$#ibxs) {
		my $dir = $ibxs[$i];
		$ibxs[$i] = $dir2ibx{$dir} ||= do {
			my $name = "unconfigured-$i";
			PublicInbox::Inbox->new({
				name => $name,
				address => [ "$name\@example.com" ],
				mainrepo => $dir,
				# TODO: consumers may want to warn on this:
				#-unconfigured => 1,
			});
		};
	}
	@ibxs;
}

# TODO: make Devel::Peek optional, only used for daemon
my @base_mod = qw(Email::MIME Date::Parse Devel::Peek);
my @over_mod = qw(DBD::SQLite DBI);
my %mod_groups = (
	-index => [ @base_mod, @over_mod ],
	-base => \@base_mod,
	-search => [ @base_mod, @over_mod, 'Search::Xapian' ],
);

sub scan_ibx_modules ($$) {
	my ($mods, $ibx) = @_;
	if (!$ibx->{indexlevel} || $ibx->{indexlevel} ne 'basic') {
		$mods->{'Search::Xapian'} = 1;
	} else {
		$mods->{$_} = 1 foreach @over_mod;
	}
}

sub check_require {
	my (@mods) = @_;
	my $err = {};
	while (my $mod = shift @mods) {
		if (my $groups = $mod_groups{$mod}) {
			push @mods, @$groups;
		} else {
			eval "require $mod";
			$err->{$mod} = $@ if $@;
		}
	}
	scalar keys %$err ? $err : undef;
}

sub missing_mod_msg {
	my ($err) = @_;
	my @mods = map { "`$_'" } sort keys %$err;
	my $last = pop @mods;
	@mods ? (join(', ', @mods)."' and $last") : $last
}

sub require_or_die {
	my $err = check_require(@_) or return;
	die missing_mod_msg($err)." required for $0\n";
}

sub indexlevel_ok_or_die ($) {
	my ($indexlevel) = @_;
	my $req;
	if ($indexlevel eq 'basic') {
		$req = '-index';
	} elsif ($indexlevel =~ /\A(?:medium|full)\z/) {
		$req = '-search';
	} else {
		die <<"";
invalid indexlevel=$indexlevel (must be `basic', `medium', or `full')

	}
	my $err = check_require($req) or return;
	die missing_mod_msg($err) ." required for indexlevel=$indexlevel\n";
}

sub index_inbox {
	my ($ibx, $opt) = @_;
	my $jobs = delete $opt->{jobs} if $opt;
	if (ref($ibx) && ($ibx->{version} || 1) == 2) {
		eval { require PublicInbox::V2Writable };
		die "v2 requirements not met: $@\n" if $@;
		my $v2w = eval {
			PublicInbox::V2Writable->new($ibx, {nproc=>$jobs});
		};
		if (defined $jobs) {
			if ($jobs == 0) {
				$v2w->{parallel} = 0;
			} else {
				my $n = $v2w->{partitions};
				if ($jobs != ($n + 1)) {
					warn
"Unable to respect --jobs=$jobs, inbox was created with $n partitions\n";
				}
			}
		}
		my $warn_cb = $SIG{__WARN__} || sub { print STDERR @_ };
		local $SIG{__WARN__} = sub {
			$warn_cb->($v2w->{current_info}, ': ', @_);
		};
		$v2w->index_sync($opt);
	} else {
		require PublicInbox::SearchIdx;
		my $s = PublicInbox::SearchIdx->new($ibx, 1);
		$s->index_sync($opt);
	}
}

1;
