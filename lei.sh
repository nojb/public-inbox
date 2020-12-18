#!/bin/sh -e
# symlink this file to a directory in PATH to run lei (or anything in script/*)
# without needing perms to install globally.  Used by "make symlink-install"
p=$(realpath "$0" || readlink "$0") # neither is POSIX, but common
p=$(dirname "$p") c=$(basename "$0") # both are POSIX
exec ${PERL-perl} -w -I"$p"/lib "$p"/script/"${c%.sh}" "$@"
: this script is too short to copyright
