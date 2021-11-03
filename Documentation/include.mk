# Copyright (C) 2013-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
all::

RSYNC = rsync
RSYNC_DEST = public-inbox.org:/srv/public-inbox/
AWK = awk
MAN = man
LEXGROG = lexgrog

# this is "xml" on FreeBSD and maybe some other distros:
XMLSTARLET = xmlstarlet

# libgraph-easy-perl from Debian, Graph::Easy from CPAN
GRAPH_EASY = graph-easy

# same as pod2text
COLUMNS = 76

INSTALL = install
PODMAN = pod2man
PODMAN_OPTS = -v --stderr -d 1993-10-02 -c 'public-inbox user manual'
PODMAN_OPTS += -r public-inbox.git
podman = $(PODMAN) $(PODMAN_OPTS)
PODTEXT = pod2text
PODTEXT_OPTS = --stderr
podtext = $(PODTEXT) $(PODTEXT_OPTS)

all:: man

manpages = $(man1) $(man5) $(man7) $(man8)

man: $(manpages)

prefix ?= $(PREFIX)
prefix ?= $(HOME)
mandir ?= $(INSTALLMAN1DIR)/..
man5dir = $(mandir)/man5
man7dir = $(mandir)/man7
man8dir = $(mandir)/man8

install-man: man
	$(INSTALL) -d -m 755 $(DESTDIR)$(INSTALLMAN1DIR)
	$(INSTALL) -d -m 755 $(DESTDIR)$(man5dir)
	$(INSTALL) -d -m 755 $(DESTDIR)$(man7dir)
	$(INSTALL) -d -m 755 $(DESTDIR)$(man8dir)
	$(INSTALL) -m 644 $(man1) $(DESTDIR)$(INSTALLMAN1DIR)
	$(INSTALL) -m 644 $(man5) $(DESTDIR)$(man5dir)
	$(INSTALL) -m 644 $(man7) $(DESTDIR)$(man7dir)
	$(INSTALL) -m 644 $(man8) $(DESTDIR)$(man8dir)

doc_install :: install-man

check :: check-man
check_man = $(AWK) \
	'{gsub(/\b./,"")}$$0 !~ /\.onion/&&length>80{print;e=1}END{exit(e)}' \
	>&2

check-man :: $(check_80)

check-lexgrog :: $(check_lexgrog)

all :: $(docs)

txt2pre = $(PERL) -I lib ./Documentation/txt2pre >$@

Documentation/standards.txt : Documentation/standards.perl
	$(PERL) -w Documentation/standards.perl >$@+
	touch -r Documentation/standards.perl $@+
	mv $@+ $@

# flow.txt is checked into git since Graph::Easy isn't in many distros
Documentation/flow.txt : Documentation/flow.ge
	(sed -ne '1,/^$$/p' <Documentation/flow.ge; \
		$(GRAPH_EASY) Documentation/flow.ge || \
			cat Documentation/flow.txt; \
		echo; \
		sed -ne '/^# Copyright/,$$p' <Documentation/flow.ge \
		) >$@+
	touch -r Documentation/flow.ge $@+
	mv $@+ $@

Documentation/lei-q.pod : lib/PublicInbox/Search.pm Documentation/common.perl
	$(PERL) -I lib -w Documentation/common.perl $@

NEWS NEWS.atom NEWS.html : $(news_deps)
	$(PERL) -I lib -w Documentation/mknews.perl $@ $(RELEASES)

# check for internal API changes:
check :: NEWS .NEWS.atom.check NEWS.html

.NEWS.atom.check: NEWS.atom
	$(XMLSTARLET) val NEWS.atom || \
		{ e=$$?; test $$e -eq 0 || test $$e -eq 127; }
	>$@

html: $(docs_html)

doc: $(docs)

%.gz: %
	gzip -9 --rsyncable <$< >$@+
	touch -r $< $@+
	mv $@+ $@

gz-doc: $(gz_docs)

rsync-doc: NEWS.atom.gz
	# /usr/share/doc/rsync/scripts/git-set-file-times{.gz} on Debian systems
	# It is also at: https://yhbt.net/git-set-file-times
	-git set-file-times $(docs) $(txt)
	$(MAKE) gz-doc
	$(RSYNC) --chmod=Fugo=r -av $(rsync_docs) $(RSYNC_DEST)

clean-doc:
	$(RM_F) $(man1) $(man5) $(man7) $(man8) $(gz_docs) $(docs_html) \
		$(mantxt) \
		NEWS NEWS.atom NEWS.html Documentation/standards.txt \
		Documentation/flow.html Documentation/flow.html.gz \
		Documentation/flow.txt.gz

clean :: clean-doc

# No camel-cased tarballs or pathnames which MakeMaker creates,
# this may not always be a Perl project.  This should match what
# cgit generate, since git maintainers ensure git-archive has
# stable tar output
DIST_TREE = HEAD^{tree}
DIST_VER =
git-dist :
	ver=$$(git describe $(DIST_VER) | sed -ne s/v//p); \
	pkgpfx=public-inbox-$$ver; \
	git archive --prefix=$$pkgpfx/ --format=tar $(DIST_TREE) \
		| gzip -n >$$pkgpfx.tar.gz; \
	echo $$pkgpfx.tar.gz created
