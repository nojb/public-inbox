#!/usr/bin/perl -w
# Copyright (C) 2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# prints a manpage to stdout
use strict;
my $xapmsg = 'See https://xapian.org/ for more information on Xapian';
my $usage = "$0 /path/to/manpage.SECTION.txt";
my $manpage = shift or die $usage;
my $MAN = $ENV{MAN} || 'man';
my @args;
$manpage = (split('/', $manpage))[-1];
$manpage =~ s/\.txt\z//;
$manpage =~ s/\A\.//; # no leading dot (see Documentation/include.mk)
$manpage =~ s/\.(\d+.*)\z// and push @args, $1; # section
push @args, $manpage;

# don't use UTF-8 characters which readers may not have fonts for
$ENV{LC_ALL} = $ENV{LANG} = 'C';
$ENV{COLUMNS} = '76'; # same as pod2text default
$ENV{PAGER} = 'cat';
my $cmd = join(' ', $MAN, @args);
system($MAN, @args) and die "$cmd failed: $!\n";
$manpage =~ /\A(?:copydatabase|xapian-compact)\z/ and
	print "\n\n", $xapmsg, "\n";

# touch -r $(man -w $section $manpage) output.txt
if (-f \*STDOUT) {
	open(my $fh, '-|', $MAN, '-w', @args) or die "$MAN -w broken?: $!\n";
	chomp(my $path = <$fh>);
	my @st = stat($path) or die "stat($path) failed: $!\n";
	# 9 - mtime
	utime($st[9], $st[9], \*STDOUT) or die "utime(STDOUT) failed: $!\n";
}
