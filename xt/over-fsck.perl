#!perl -w
# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# unstable dev script, chasing a bug which may be in LeiSavedSearch->is_dup
use v5.12;
use Data::Dumper;
use PublicInbox::OverIdx;
@ARGV == 1 or die "Usage: $0 /path/to/over.sqlite3\n";
my $over = PublicInbox::OverIdx->new($ARGV[0]);
my $dbh = $over->dbh;
$dbh->do('PRAGMA mmap_size = '.(2 ** 48));
my $num = 0;
my ($err, $none, $nr, $ids);
$Data::Dumper::Useqq = $Data::Dumper::Sortkeys = 1;
do {
	$ids = $over->ids_after(\$num);
	$nr += @$ids;
	for my $n (@$ids) {
		my $smsg = $over->get_art($n);
		if (!$smsg) {
			warn "#$n article missing\n";
			++$err;
			next;
		}
		my $exp = $smsg->{blob};
		if ($exp eq '') {
			++$none if $smsg->{bytes};
			next;
		}
		my $xr3 = $over->get_xref3($n, 1);
		my $found;
		for my $r (@$xr3) {
			$r->[2] = unpack('H*', $r->[2]);
			$found = 1 if $r->[2] eq $exp;
		}
		if (!$found) {
			warn Dumper([$smsg, $xr3 ]);
			++$err;
		}
	}
} while (@$ids);
warn "$none/$nr had no blob (external?)\n" if $none;
warn "$err errors\n" if $err;
exit($err ? 1 : 0);
