#!/usr/bin/perl -w
# Copyright (C) 2013, Eric Wong <normalperson@yhbt.net> and all contributors
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
use strict;
use ExtUtils::MakeMaker;
WriteMakefile(
	NAME => 'public-inbox',
	VERSION => '0.0.0',
	AUTHOR => 'Eric Wong <normalperson@yhbt.net>',
	ABSTRACT => 'public-inbox server infrastructure',
	EXE_FILES => [qw/public-inbox-mda public-inbox-cgi/],
	PREREQ_PM => {
		# note: we use ssoma(1) and spamc(1),
		# NOT the Perl modules
		# We also depend on git through ssoma.
		'Email::MIME' => 0,
		'Email::MIME::ContentType' => 0,
		'Email::Filter' => 0,
		'Email::Address' => 0,
		'Mail::Thread' => '2.5', # 2.5+ needed for Email::Simple compat
		'Date::Parse' => 0,
		'Encode::MIME::Header' => 0,
		'XML::Atom::SimpleFeed' => 0,
		'IPC::Open2' => 0,
		'IPC::Run' => 0,
		'File::Path::Expand' => 0,
		'CGI' => 0,
		'URI::Escape' => 0,
		# We have more test dependencies, but do not force
		# users to install them
	},
);

sub MY::postamble {
  <<'EOF';
RSYNC_DEST = public-inbox.org:/srv/public-inbox/
docs = README COPYING INSTALL $(shell git ls-files Documentation/ '*.txt')
gz_docs = $(addsuffix .gz, $(docs))
%.gz: %
	gzip -9 --rsyncable < $< > $@+
	touch -r $< $@+
	mv $@+ $@

gz-docs: $(gz_docs)
rsync-docs:
	git set-file-times $(docs)
	$(MAKE) gz-docs
	rsync --chmod=Fugo=r -av $(gz_docs) $(docs) $(RSYNC_DEST)

EOF
}
