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
require PublicInbox::Config;

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
		close $fh or die "error in $cmd (cwd:$cd): $!\n";
		chomp $dir;
		$$ver = 1 if $ver;
		return abs_path($cd) if ($dir eq '.' && defined $cd);
		abs_path($dir);
	}
}

# for unconfigured inboxes
sub detect_indexlevel ($) {
	my ($ibx) = @_;

	# brand new or never before indexed inboxes default to full
	return 'full' unless $ibx->over;
	delete $ibx->{over}; # don't leave open FD lying around

	my $l = 'basic';
	my $srch = $ibx->search or return $l;
	delete $ibx->{search}; # don't leave open FD lying around
	if (my $xdb = $srch->xdb) {
		$l = 'full';
		my $m = $xdb->get_metadata('indexlevel');
		if ($m eq 'medium') {
			$l = $m;
		} elsif ($m ne '') {
			warn <<"";
$ibx->{inboxdir} has unexpected indexlevel in Xapian: $m

		}
	}
	$l;
}

sub unconfigured_ibx ($$) {
	my ($dir, $i) = @_;
	my $name = "unconfigured-$i";
	PublicInbox::Inbox->new({
		name => $name,
		address => [ "$name\@example.com" ],
		inboxdir => $dir,
		# TODO: consumers may want to warn on this:
		#-unconfigured => 1,
	});
}

sub resolve_inboxes ($;$$) {
	my ($argv, $opt, $cfg) = @_;
	require PublicInbox::Inbox;
	$opt ||= {};

	$cfg //= eval { PublicInbox::Config->new };
	if ($opt->{all}) {
		my $cfgfile = PublicInbox::Config::default_file();
		$cfg or die "--all specified, but $cfgfile not readable\n";
		@$argv and die "--all specified, but directories specified\n";
	}

	my $min_ver = $opt->{-min_inbox_version} || 0;
	my (@old, @ibxs);
	my %dir2ibx;
	if ($cfg) {
		$cfg->each_inbox(sub {
			my ($ibx) = @_;
			$ibx->{version} ||= 1;
			my $path = abs_path($ibx->{inboxdir});
			if (defined($path)) {
				$dir2ibx{$path} = $ibx;
			} else {
				warn <<EOF;
W: $ibx->{name} $ibx->{inboxdir}: $!
EOF
			}
		});
	}
	if ($opt->{all}) {
		my @all = values %dir2ibx;
		@all = grep { $_->{version} >= $min_ver } @all;
		push @ibxs, @all;
	} else { # directories specified on the command-line
		my $i = 0;
		my @dirs = @$argv;
		push @dirs, '.' unless @dirs;
		foreach (@dirs) {
			my $v;
			my $dir = resolve_repo_dir($_, \$v);
			if ($v < $min_ver) {
				push @old, $dir;
				next;
			}
			my $ibx = $dir2ibx{$dir} ||= unconfigured_ibx($dir, $i);
			$i++;
			push @ibxs, $ibx;
		}
	}
	if (@old) {
		die "inboxes $min_ver inboxes not supported by $0\n\t",
		    join("\n\t", @old), "\n";
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
	my ($ibx, $im, $opt) = @_;
	my $jobs = delete $opt->{jobs} if $opt;
	if (ref($ibx) && ($ibx->{version} || 1) == 2) {
		eval { require PublicInbox::V2Writable };
		die "v2 requirements not met: $@\n" if $@;
		my $v2w = $im // eval { $ibx->importer(0) } || eval {
			PublicInbox::V2Writable->new($ibx, {nproc=>$jobs});
		};
		if (defined $jobs) {
			if ($jobs == 0) {
				$v2w->{parallel} = 0;
			} else {
				my $n = $v2w->{shards};
				if ($jobs != ($n + 1) && !$opt->{reshard}) {
					warn
"Unable to respect --jobs=$jobs, inbox was created with $n shards\n";
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

sub progress_prepare ($) {
	my ($opt) = @_;

	# public-inbox-index defaults to quiet, -xcpdb and -compact do not
	if (defined($opt->{quiet}) && $opt->{quiet} < 0) {
		$opt->{quiet} = !$opt->{verbose};
	}
	if ($opt->{quiet}) {
		open my $null, '>', '/dev/null' or
			die "failed to open /dev/null: $!\n";
		$opt->{1} = fileno($null); # suitable for spawn() redirect
		$opt->{-dev_null} = $null;
	} else {
		$opt->{verbose} ||= 1;
		$opt->{-progress} = sub { print STDERR @_ };
	}
}

1;
