#!/usr/bin/perl -w
# Copyright (C) 2013-2015 all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
use strict;
use ExtUtils::MakeMaker;
my @EXE_FILES = split("\n", `git ls-files 'script/*' 2>/dev/null`);
my $PM_FILES = `git ls-files lib '*.pm' 2>/dev/null`;
$PM_FILES =~ tr/\n/ /;

WriteMakefile(
	NAME => 'PublicInbox',
	VERSION => '0.0.0',
	AUTHOR => 'Eric Wong <e@80x24.org>',
	ABSTRACT => 'public-inbox server infrastructure',
	EXE_FILES => \@EXE_FILES,
	PREREQ_PM => {
		# note: we use spamc(1), NOT the Perl modules
		# We also depend on git.
		# Keep this sorted and synced to the INSTALL document
		'Date::Parse' => 0,
		'Email::MIME' => 0,
		'Email::MIME::ContentType' => 0,
		'Email::Simple' => 0,
		'Encode::MIME::Header' => 0,
		'Plack' => 0,
		'URI::Escape' => 0,
		# We have more test dependencies, but do not force
		# users to install them
	},
);

sub MY::postamble {
  <<EOF;
# support using eatmydata to speed up tests (apt-get install eatmydata):
# https://www.flamingspork.com/projects/libeatmydata/
EATMYDATA =
-include config.mak
-include Documentation/include.mk
N ?= \$(shell echo \$\$(( \$\$(nproc 2>/dev/null || echo 2) + 1)))
SCRIPTS := scripts/ssoma-replay
my_syntax := \$(addsuffix .syntax, $PM_FILES \$(EXE_FILES) \$(SCRIPTS))


%.syntax ::
	@\$(PERL) -I lib -c \$(subst .syntax,,\$@)

syntax:: \$(my_syntax)

check-manifest :: MANIFEST
	if git ls-files >\$<.gen 2>&1; then diff -u \$< \$<.gen; fi

check:: pure_all check-manifest
	\$(EATMYDATA) prove -lv -j\$(N)

EOF
}
