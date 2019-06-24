#!/usr/bin/perl -w
# Copyright (C) 2013-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use ExtUtils::MakeMaker;
open my $m, '<', 'MANIFEST' or die "open(MANIFEST): $!\n";
chomp(my @manifest = (<$m>));
my @EXE_FILES = grep(m!^script/!, @manifest);
my $PM_FILES = join(' ', grep(m!^lib/.*\.pm$!, @manifest));

# Don't waste user's disk space by installing some pods from
# imported code or internal use only
my %man3 = map {; # semi-colon tells Perl this is a BLOCK (and not EXPR)
	my $base = $_;
	my $mod = $base;
	$mod =~ s/\.\w+\z//;
	"lib/PublicInbox/$_" => "blib/man3/PublicInbox::$mod.3"
} qw(Git.pm Import.pm WWW.pod);

WriteMakefile(
	NAME => 'PublicInbox',
	VERSION => '1.1.0-pre1',
	AUTHOR => 'Eric Wong <e@80x24.org>',
	ABSTRACT => 'public-inbox server infrastructure',
	EXE_FILES => \@EXE_FILES,
	PREREQ_PM => {
		# note: we use spamc(1), NOT the Perl modules
		# We also depend on git.
		# Keep this sorted and synced to the INSTALL document
		'Date::Parse' => 0,

		# libperl$PERL_VERSION,
		# `perl5' on FreeBSD
		# perl-Digest-SHA on RH-based
		'Digest::SHA' => 0,
		'Email::MIME' => 0,

		# the following should be pulled in by Email::MIME:
		'Email::MIME::ContentType' => 0,
		'Email::Simple' => 0,

		# libperl$PERL_VERSION or libencode-perl on Debian,
		# `perl5' on FreeBSD
		'Encode' => 0,

		# TODO: these should really be made optional...
		'Plack' => 0,
		'URI::Escape' => 0,

		# We have more test dependencies, but do not force
		# users to install them.  See INSTALL

		# All Perl installs I know about have these, but RH-based
		# distros make them separate even though 'perl' pulls them in
		'File::Path' => 0,
		'File::Temp' => 0,
		'Getopt::Long' => 0,
		'Exporter' => 0,
		# ExtUtils::MakeMaker # this file won't run w/o it...
	},
	MAN3PODS => \%man3,
);

sub MY::postamble {
  <<EOF;
# support using eatmydata to speed up tests (apt-get install eatmydata):
# https://www.flamingspork.com/projects/libeatmydata/
EATMYDATA =
N = \$\$(( \$\$(nproc 2>/dev/null || gnproc 2>/dev/null || echo 2) + 1 ))
-include config.mak
-include Documentation/include.mk
SCRIPTS := scripts/ssoma-replay
syn_files = $PM_FILES \$(EXE_FILES) \$(SCRIPTS) \$(wildcard t/*.t)
my_syntax = \$(addsuffix .syntax, \$(syn_files))
changed = \$(shell git ls-files -m)

%.syntax ::
	@\$(PERL) -w -I lib -c \$(subst .syntax,,\$@)

syntax:: \$(filter-out lib/PublicInbox/DSKQXS.pm.syntax,\$(my_syntax))

dsyn :: \$(addsuffix .syntax, \$(filter \$(changed), \$(syn_files)))

check-manifest :: MANIFEST
	if git ls-files >\$?.gen 2>&1; then diff -u \$? \$?.gen; fi

check:: pure_all check-manifest
	\$(EATMYDATA) prove -lvw -j\$(N)

lib/PublicInbox/UserContent.pm :: contrib/css/216dark.css
	\$(PERL) -I lib \$@ \$?

EOF
}
