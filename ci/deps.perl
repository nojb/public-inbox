#!/usr/bin/perl -w
# Copyright (C) 2019-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# Helper script for installing/uninstalling packages for CI use
# Intended for use on non-production chroots or VMs since it
# changes installed packages
use strict;
my $usage = "$0 PKG_FMT PROFILE [PROFILE_MOD]";
my $pkg_fmt = shift;
@ARGV or die $usage, "\n";

my @test_essential = qw(Test::Simple); # we actually use Test::More

# package profiles
my $profiles = {
	# the smallest possible profile for testing
	essential => [ qw(
		git
		perl
		Digest::SHA
		Encode
		ExtUtils::MakeMaker
		IO::Compress::Gzip
		URI
		), @test_essential ],

	# everything optional for normal use
	optional => [ qw(
		Date::Parse
		BSD::Resource
		DBD::SQLite
		DBI
		Inline::C
		Net::Server
		Plack
		Plack::Test
		Plack::Middleware::ReverseProxy
		Search::Xapian
		Socket6
		highlight.pm
		xapian-compact
		) ],

	# optional developer stuff
	devtest => [ qw(
		XML::TreePP
		curl
		w3m
		Plack::Test::ExternalServer
		) ],
};

# account for granularity differences between package systems and OSes
my @precious;
if ($^O eq 'freebsd') {
	@precious = qw(perl curl Socket6 IO::Compress::Gzip);
} elsif ($pkg_fmt eq 'rpm') {
	@precious = qw(perl curl);
}

if (@precious) {
	my $re = join('|', map { quotemeta($_) } @precious);
	for my $list (values %$profiles) {
		@$list = grep(!/\A(?:$re)\z/, @$list);
	}
	push @{$profiles->{essential}}, @precious;
}


# bare minimum for v2
$profiles->{v2essential} = [ @{$profiles->{essential}}, qw(DBD::SQLite DBI) ];

# package names which can't be mapped automatically:
my $non_auto = {
	'perl' => { pkg => 'perl5' },
	'Date::Parse' => {
		deb => 'libtimedate-perl',
		pkg => 'p5-TimeDate',
		rpm => 'perl-TimeDate',
	},
	'Digest::SHA' => {
		deb => 'perl', # libperl5.XX, but the XX varies
		pkg => 'perl5',
	},
	'Encode' => {
		deb => 'perl', # libperl5.XX, but the XX varies
		pkg => 'perl5',
		rpm => 'perl-Encode',
	},
	'ExtUtils::MakeMaker' => {
		deb => 'perl', # perl-modules-5.xx
		pkg => 'perl5',
		rpm => 'perl-ExtUtils-MakeMaker',
	},
	'IO::Compress::Gzip' => {
		deb => 'perl', # perl-modules-5.xx
		pkg => 'perl5',
		rpm => 'perl-IO-Compress',
	},
	'DBD::SQLite' => { deb => 'libdbd-sqlite3-perl' },
	'Plack::Test' => {
		deb => 'libplack-perl',
		pkg => 'p5-Plack',
		rpm => 'perl-Plack-Test',
	},
	'URI' => {
		deb => 'liburi-perl',
		pkg => 'p5-URI',
		rpm => 'perl-URI',
	},
	'Test::Simple' => {
		deb => 'perl', # perl-modules-5.XX, but the XX varies
		pkg => 'perl5',
		rpm => 'perl-Test-Simple',
	},
	'highlight.pm' => {
		deb => 'libhighlight-perl',
		pkg => [],
		rpm => [],
	},

	# we call xapian-compact(1) in public-inbox-compact(1)
	'xapian-compact' => {
		deb => 'xapian-tools',
		pkg => 'xapian-core',
		rpm => 'xapian-core', # ???
	},

	# OS-specific
	'IO::KQueue' => {
		deb => [],
		pkg => 'p5-IO-KQueue',
		rpm => [],
	},
};

my (@pkg_install, @pkg_remove, %all);
for my $ary (values %$profiles) {
	$all{$_} = \@pkg_remove for @$ary;
}
if ($^O eq 'freebsd') {
	$all{'IO::KQueue'} = \@pkg_remove;
}
$profiles->{all} = [ keys %all ]; # pseudo-profile for all packages

# parse the profile list from the command-line
for my $profile (@ARGV) {
	if ($profile =~ s/-\z//) {
		# like apt-get, trailing "-" means remove
		profile2dst($profile, \@pkg_remove);
	} else {
		profile2dst($profile, \@pkg_install);
	}
}

# fill in @pkg_install and @pkg_remove:
while (my ($pkg, $dst_pkg_list) = each %all) {
	push @$dst_pkg_list, list(pkg2ospkg($pkg, $pkg_fmt));
}

my @apt_opts =
	qw(-o APT::Install-Recommends=false -o APT::Install-Suggests=false);

# OS-specific cleanups appreciated

if ($pkg_fmt eq 'deb') {
	my @quiet = $ENV{V} ? () : ('-q');
	root('apt-get', @apt_opts, qw(install --purge -y), @quiet,
		@pkg_install,
		# apt-get lets you suffix a package with "-" to
		# remove it in an "install" sub-command:
		map { "$_-" } @pkg_remove);
	root('apt-get', @apt_opts, qw(autoremove --purge -y), @quiet);
} elsif ($pkg_fmt eq 'pkg') {
	my @quiet = $ENV{V} ? () : ('-q');
	# FreeBSD, maybe other *BSDs are similar?

	# don't remove stuff that isn't installed:
	exclude_uninstalled(\@pkg_remove);
	root(qw(pkg remove -y), @quiet, @pkg_remove) if @pkg_remove;
	root(qw(pkg install -y), @quiet, @pkg_install) if @pkg_install;
	root(qw(pkg autoremove -y), @quiet);
# TODO: yum / rpm support
} elsif ($pkg_fmt eq 'rpm') {
	my @quiet = $ENV{V} ? () : ('-q');
	exclude_uninstalled(\@pkg_remove);
	root(qw(yum remove -y), @quiet, @pkg_remove) if @pkg_remove;
	root(qw(yum install -y), @quiet, @pkg_install) if @pkg_install;
} else {
	die "unsupported package format: $pkg_fmt\n";
}
exit 0;


# map a generic package name to an OS package name
sub pkg2ospkg {
	my ($pkg, $fmt) = @_;

	# check explicit overrides, first:
	if (my $ospkg = $non_auto->{$pkg}->{$fmt}) {
		return $ospkg;
	}

	# check common Perl module name patterns:
	if ($pkg =~ /::/ || $pkg =~ /\A[A-Z]/) {
		if ($fmt eq 'deb') {
			$pkg =~ s/::/-/g;
			$pkg =~ tr/A-Z/a-z/;
			return "lib$pkg-perl";
		} elsif ($fmt eq 'rpm') {
			$pkg =~ s/::/-/g;
			return "perl-$pkg"
		} elsif ($fmt eq 'pkg') {
			$pkg =~ s/::/-/g;
			return "p5-$pkg"
		} else {
			die "unsupported package format: $fmt for $pkg\n"
		}
	}

	# use package name as-is (e.g. 'curl' or 'w3m')
	$pkg;
}

# maps a install profile to a package list (@pkg_remove or @pkg_install)
sub profile2dst {
	my ($profile, $dst_pkg_list) = @_;
	if (my $pkg_list = $profiles->{$profile}) {
		$all{$_} = $dst_pkg_list for @$pkg_list;
	} elsif ($all{$profile}) { # $profile is just a package name
		$all{$profile} = $dst_pkg_list;
	} else {
		die "unrecognized profile or package: $profile\n";
	}
}

sub exclude_uninstalled {
	my ($list) = @_;
	my %inst_check = (
		pkg => sub { system(qw(pkg info -q), $_[0]) == 0 },
		deb => sub { system("dpkg -s $_[0] >/dev/null 2>&1") == 0 },
		rpm => sub { system("rpm -qs $_[0] >/dev/null 2>&1") == 0 },
	);

	my $cb = $inst_check{$pkg_fmt} || die <<"";
don't know how to check install status for $pkg_fmt

	my @tmp;
	for my $pkg (@$list) {
		push @tmp, $pkg if $cb->($pkg);
	}
	@$list = @tmp;
}

sub root {
	print join(' ', @_), "\n";
	return if $ENV{DRY_RUN};
	return if system(@_) == 0;
	warn 'command failed: ', join(' ', @_), "\n";
	exit($? >> 8);
}

# ensure result can be pushed into an array:
sub list {
	my ($pkg) = @_;
	ref($pkg) eq 'ARRAY' ? @$pkg : $pkg;
}
