#!/bin/sh
# Copyright (C) 2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Prints OS-specific package profiles to stdout (one per-newline) to use
# as command-line args for ci/deps.perl.  Called automatically by ci/run.sh

# set by os-release(5) or similar
ID= VERSION_ID=
case $(uname -o) in
GNU/Linux)
	for f in /etc/os-release /usr/lib/os-release
	do
		test -f $f || continue
		. $f

		# Debian sid (and testing) have no VERSION_ID
		case $ID--$VERSION_ID in
		debian--)
			case $PRETTY_NAME in
			*/sid) VERSION_ID=sid ;;
			*)
				echo >&2 "$ID, but no VERSION_ID"
				echo >&2 "==> $f <=="
				cat >&2 $f
				exit 1
				;;
			esac
			;;
		esac

		case $ID--$VERSION_ID in
		-|*--|--*) continue ;;
		*--*) break ;;
		esac
	done
	;;
FreeBSD)
	ID=freebsd
	VERSION_ID=$(uname -r | cut -d . -f 1)
	test "$VERSION_ID" -lt 11 && {
		echo >&2 "ID=$ID $(uname -r) too old to support";
		exit 1
	}
esac

case $ID in
freebsd) PKG_FMT=pkg ;;
debian|ubuntu) PKG_FMT=deb ;;
centos|redhat|fedora) PKG_FMT=rpm ;;
*) echo >&2 "PKG_FMT undefined for ID=$ID in $0"
esac

case $ID-$VERSION_ID in
freebsd-11|freebsd-12) sed "s/^/$PKG_FMT /" <<EOF
all devtest-
all devtest IO::KQueue-
all devtest IO::KQueue
v2essential
essential
essential devtest-
EOF
	;;
debian-sid|debian-9|debian-10) sed "s/^/$PKG_FMT /" <<EOF
all devtest
all devtest Search::Xapian-
all devtest-
v2essential
essential
essential devtest-
EOF
	;;
esac
