# Copyright (C) 2013-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
all::

# Note: some GNU-isms present and required to build docs
# (including manpages), but at least this should not trigger
# warnings with BSD make(1) when running "make check"
# Maybe it's not worth it to support non-GNU make, though...
RSYNC = rsync
RSYNC_DEST = public-inbox.org:/srv/public-inbox/
AWK = awk
MAN = man

# this is "xml" on FreeBSD and maybe some other distros:
XMLSTARLET = xmlstarlet
AWK = awk

# same as pod2text
COLUMNS = 76

txt := INSTALL README COPYING TODO HACKING
dtxt := design_notes.txt design_www.txt dc-dlvr-spam-flow.txt hosted.txt
dtxt += marketing.txt
dtxt += standards.txt
dtxt := $(addprefix Documentation/, $(dtxt))
docs := $(txt) $(dtxt)

INSTALL = install
PODMAN = pod2man
PODMAN_OPTS = -v --stderr -d 1993-10-02 -c 'public-inbox user manual'
PODMAN_OPTS += -r public-inbox.git
podman = $(PODMAN) $(PODMAN_OPTS)
PODTEXT = pod2text
PODTEXT_OPTS = --stderr
podtext = $(PODTEXT) $(PODTEXT_OPTS)

# MakeMaker only seems to support manpage sections 1 and 3...
m1 =
m1 += public-inbox-compact
m1 += public-inbox-convert
m1 += public-inbox-edit
m1 += public-inbox-httpd
m1 += public-inbox-index
m1 += public-inbox-init
m1 += public-inbox-mda
m1 += public-inbox-nntpd
m1 += public-inbox-watch
m1 += public-inbox-xcpdb
m5 =
m5 += public-inbox-config
m5 += public-inbox-v1-format
m5 += public-inbox-v2-format
m7 =
m7 += public-inbox-overview
m8 =
m8 += public-inbox-daemon

man1 := $(addsuffix .1, $(m1))
man5 := $(addsuffix .5, $(m5))
man7 := $(addsuffix .7, $(m7))
man8 := $(addsuffix .8, $(m8))

all:: man html

manpages = $(man1) $(man5) $(man7) $(man8)

man: $(manpages)

prefix ?= $(PREFIX)
prefix ?= $(HOME)
mandir ?= $(prefix)/share/man
man1dir = $(mandir)/man1
man5dir = $(mandir)/man5
man7dir = $(mandir)/man7
man8dir = $(mandir)/man8

install-man: man
	$(INSTALL) -d -m 755 $(DESTDIR)$(man1dir)
	$(INSTALL) -d -m 755 $(DESTDIR)$(man5dir)
	$(INSTALL) -d -m 755 $(DESTDIR)$(man7dir)
	$(INSTALL) -d -m 755 $(DESTDIR)$(man8dir)
	$(INSTALL) -m 644 $(man1) $(DESTDIR)$(man1dir)
	$(INSTALL) -m 644 $(man5) $(DESTDIR)$(man5dir)
	$(INSTALL) -m 644 $(man7) $(DESTDIR)$(man7dir)
	$(INSTALL) -m 644 $(man8) $(DESTDIR)$(man8dir)

doc_install :: install-man

%.1 %.5 %.7 %.8 : Documentation/%.pod
	$(podman) -s $(subst .,,$(suffix $@)) $< $@+ && mv $@+ $@

# n.b. not sure if our usage of man(1) is portable or not, so not
# enabled by default "check" target:
# check :: check-man
check_man = @echo CHECK80 $<;COLS=80 $(MAN) ./$^ | \
	$(AWK) 'length>80{print;err=1}END{exit(err)}' >&2

%.1.cols : %.1; $(check_man)
%.5.cols : %.5; $(check_man)
%.7.cols : %.7; $(check_man)
%.8.cols : %.8; $(check_man)

check-man :: $(addsuffix .cols, $(manpages))

manuals :=
manuals += $(m1)
manuals += $(m5)
manuals += $(m7)
manuals += $(m8)

mantxt = $(addprefix Documentation/, $(addsuffix .txt, $(manuals)))
docs += $(mantxt)
dtxt += $(mantxt)
docs += NEWS

all :: $(docs)

Documentation/%.txt : Documentation/%.pod
	$(podtext) $< $@+ && touch -r $< $@+ && mv $@+ $@

txt2pre = $(PERL) -I lib ./Documentation/txt2pre <$< >$@+ && \
	touch -r $< $@+ && mv $@+ $@

Documentation/standards.txt : Documentation/standards.perl
	$(PERL) $< >$@+ && touch -r $< $@+ && mv $@+ $@

RELEASES =
RELEASES += v1.1.0-pre1
RELEASES += v1.0.0

NEWS NEWS.atom NEWS.html :
	$(PERL) -I lib -w Documentation/mknews.perl $@ $(RELEASES)

# check for internal API changes:
check :: NEWS check-NEWS.atom NEWS.html

check-NEWS.atom: NEWS.atom
	$(XMLSTARLET) val NEWS.atom || \
		{ e=$$?; test $$e -eq 0 || test $$e -eq 127; }

Documentation/%.html: Documentation/%.txt
	$(txt2pre)

%.html: %
	$(txt2pre)

docs_html := $(addsuffix .html, $(subst .txt,,$(dtxt)) $(txt)) NEWS.html
html: $(docs_html)
gz_docs := $(addsuffix .gz, $(docs) $(docs_html))
rsync_docs := $(gz_docs) $(docs) $(docs_html) NEWS.atom NEWS.atom.gz

# external manpages which we host ourselves, since some packages
# (currently just Xapian) doesn't host manpages themselves.
xtxt :=
xtxt += .copydatabase.1
xtxt += .xapian-compact.1
xtxt := $(addprefix Documentation/.x/, $(addsuffix .txt, $(xtxt)))
xdocs := $(xtxt)
xdocs_html := $(addsuffix .html, $(subst .txt,,$(xtxt)))
gz_xdocs := $(addsuffix .gz, $(xdocs) $(xdocs_html))
rsync_xdocs := $(gz_xdocs) $(xdocs_html) $(xdocs)
xdoc: $(xdocs) $(xdocs_html)

Documentation/.x:
	mkdir -p $@

Documentation/.x/%.txt :: | Documentation/.x
	$(PERL) -w Documentation/extman.perl $@ >$@+
	mv $@+ $@

Documentation/.x/%.html: Documentation/.x/%.txt
	$(txt2pre)

doc: $(docs)

%.gz: %
	gzip -9 --rsyncable <$< >$@+
	touch -r $< $@+
	mv $@+ $@

gz-doc: $(gz_docs)

gz-xdoc: $(gz_xdocs)

rsync-doc: NEWS.atom.gz
	# /usr/share/doc/rsync/scripts/git-set-file-times{.gz} on Debian systems
	# It is also at: https://yhbt.net/git-set-file-times
	-git set-file-times $(docs) $(txt)
	$(MAKE) gz-doc gz-xdoc
	$(RSYNC) --chmod=Fugo=r -av $(rsync_docs) $(rsync_xdocs) $(RSYNC_DEST)

clean-doc:
	$(RM) $(man1) $(man5) $(man7) $(man8) $(gz_docs) $(docs_html) $(mantxt)
	$(RM) $(gz_xdocs) $(xdocs_html) $(xdocs) NEWS NEWS.atom NEWS.html

clean :: clean-doc

pure_all ::
	@if test x"$(addprefix g, make)" != xgmake; then \
	echo W: gmake is currently required to build manpages; fi
