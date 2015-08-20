#!/usr/bin/perl -w
# Copyright (C) 2013-2015 all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
use strict;
use ExtUtils::MakeMaker;
WriteMakefile(
	NAME => 'public-inbox',
	VERSION => '0.0.0',
	AUTHOR => 'Eric Wong <normalperson@yhbt.net>',
	ABSTRACT => 'public-inbox server infrastructure',
	EXE_FILES => [qw/public-inbox-mda public-inbox.cgi
			public-inbox-learn public-inbox-init
			public-inbox-index/],
	PREREQ_PM => {
		# note: we use ssoma(1) and spamc(1), NOT the Perl modules
		# We also depend on git through ssoma.
		# Keep this sorted and synced to the INSTALL document
		'CGI' => 0,
		'Date::Parse' => 0,
		'Email::Address' => 0,
		'Email::Filter' => 0,
		'Email::MIME' => 0,
		'Email::MIME::ContentType' => 0,
		'Encode::MIME::Header' => 0,
		'File::Path::Expand' => 0,
		'IPC::Run' => 0,
		'Mail::Thread' => '2.5', # 2.5+ needed for Email::Simple compat
		'URI::Escape' => 0,
		'XML::Atom::SimpleFeed' => 0,
		# We have more test dependencies, but do not force
		# users to install them
	},
);

sub MY::postamble {
  <<'EOF';
-include Documentation/include.mk
N = $(shell echo $$(( $$(nproc 2>/dev/null || echo 2) + 1)))
check:: pure_all
	prove -lv -j$(N)

EOF
}
