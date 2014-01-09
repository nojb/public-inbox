INSTALL = install
all::
	@cat README

ROOT_FILES = etc/spamassassin/public-inbox.pre
install-root:
	@mkdir -p /etc/spamassassin
	for f in $(ROOT_FILES); do $(INSTALL) -m 0644 root/$$f /$$f; done
diff-root:
	for f in $(ROOT_FILES); do diff -u root/$$f /$$f; done

USER_FILES = .spamassassin/user_prefs
install-user:
	@mkdir -p ~/.spamassassin/
	for f in $(USER_FILES); do $(INSTALL) -m 0644 user/$$f ~/$$f; done
diff-user:
	for f in $(USER_FILES); do diff -u user/$$f ~/$$f; done
