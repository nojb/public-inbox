#!/bin/sh
# Copyright (C) 2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
set -e
SUDO=${SUDO-'sudo'} PERL=${PERL-'perl'} MAKE=${MAKE-'make'}
DO=${DO-''}

set -x
if test -f Makefile
then
	$DO $MAKE clean
fi

./ci/profiles.sh | while read args
do
	$DO $SUDO $PERL -w ci/deps.perl $args
	$DO $PERL Makefile.PL
	$DO $MAKE
	$DO $MAKE check
	$DO $MAKE clean
done
