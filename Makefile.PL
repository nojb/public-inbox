#!/usr/bin/perl -w
# Copyright (C) 2013, Eric Wong <normalperson@yhbt.net> and all contributors
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
use strict;
use ExtUtils::MakeMaker;
WriteMakefile(
	NAME => 'public-inbox',
	VERSION => '0.0.0',
	AUTHOR => 'Eric Wong <normalperson@yhbt.net>',
	ABSTRACT => 'public-inbox.org infrastructure',
	EXE_FILES => [qw/public-inbox-mda/],
	PREREQ_PM => {
	        # note: we use ssoma(1) and spamc(1),
		# NOT the Perl modules
		'Email::MIME' => 0,
		'Email::MIME::ContentType' => 0,
		'Email::Filter' => 0,
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
