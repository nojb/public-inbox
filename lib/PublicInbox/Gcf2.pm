# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# backend for a git-cat-file-workalike based on libgit2,
# other libgit2 stuff may go here, too.
package PublicInbox::Gcf2;
use strict;
use PublicInbox::Spawn qw(which popen_rd);
use Fcntl qw(LOCK_EX);
use IO::Handle; # autoflush
my (%CFG, $c_src, $lockfh);
BEGIN {
	# PublicInbox::Spawn will set PERL_INLINE_DIRECTORY
	# to ~/.cache/public-inbox/inline-c if it exists
	my $inline_dir = $ENV{PERL_INLINE_DIRECTORY} //
		die 'PERL_INLINE_DIRECTORY not defined';
	my $f = "$inline_dir/.public-inbox.lock";
	open $lockfh, '>', $f or die "failed to open $f: $!\n";
	my $pc = which($ENV{PKG_CONFIG} // 'pkg-config');
	my ($dir) = (__FILE__ =~ m!\A(.+?)/[^/]+\z!);
	my $rdr = {};
	open $rdr->{2}, '>', '/dev/null' or die "open /dev/null: $!";
	for my $x (qw(libgit2)) {
		my $l = popen_rd([$pc, '--libs', $x], undef, $rdr);
		$l = do { local $/; <$l> };
		next if $?;
		my $c = popen_rd([$pc, '--cflags', $x], undef, $rdr);
		$c = do { local $/; <$c> };
		next if $?;

		# note: we name C source files .h to prevent
		# ExtUtils::MakeMaker from automatically trying to
		# build them.
		my $f = "$dir/gcf2_$x.h";
		if (open(my $fh, '<', $f)) {
			chomp($l, $c);
			local $/;
			defined($c_src = <$fh>) or die "read $f: $!\n";
			$CFG{LIBS} = $l;
			$CFG{CCFLAGSEX} = $c;
			last;
		} else {
			die "E: $f: $!\n";
		}
	}
	die "E: libgit2 not installed\n" unless $c_src;

	# CentOS 7.x ships Inline 0.53, 0.64+ has built-in locking
	flock($lockfh, LOCK_EX) or die "LOCK_EX failed on $f: $!\n";
}

# we use Capitalized and ALLCAPS for compatibility with old Inline::C
use Inline C => Config => %CFG, BOOT => 'git_libgit2_init();';
use Inline C => $c_src;
undef $c_src;
undef %CFG;
undef $lockfh;

sub add_alt ($$) {
	my ($gcf2, $objdir) = @_;

	# libgit2 (tested 0.27.7+dfsg.1-0.2 and 0.28.3+dfsg.1-1~bpo10+1
	# in Debian) doesn't handle relative epochs properly when nested
	# multiple levels.  Add all the absolute paths to workaround it,
	# since $EXTINDEX_DIR/ALL.git/objects/info/alternates uses absolute
	# paths to reference $V2INBOX_DIR/all.git/objects and
	# $V2INBOX_DIR/all.git/objects/info/alternates uses relative paths
	# to refer to $V2INBOX_DIR/git/$EPOCH.git/objects
	#
	# See https://bugs.debian.org/975607
	if (open(my $fh, '<', "$objdir/info/alternates")) {
		chomp(my @abs_alt = grep(m!^/!, <$fh>));
		$gcf2->add_alternate($_) for @abs_alt;
	}
	$gcf2->add_alternate($objdir);
}

# Usage: $^X -MPublicInbox::Gcf2 -e 'PublicInbox::Gcf2::loop()'
# (see lib/PublicInbox/Gcf2Client.pm)
sub loop {
	my $gcf2 = new();
	my %seen;
	STDERR->autoflush(1);
	STDOUT->autoflush(1);

	while (<STDIN>) {
		chomp;
		my ($oid, $git_dir) = split(/ /, $_, 2);
		$seen{$git_dir}++ or add_alt($gcf2, "$git_dir/objects");
		if (!$gcf2->cat_oid(1, $oid)) {
			# retry once if missing.  We only get unabbreviated OIDs
			# from SQLite or Xapian DBs, here, so malicious clients
			# can't trigger excessive retries:
			warn "I: $$ $oid missing, retrying in $git_dir\n";

			$gcf2 = new();
			%seen = ($git_dir => 1);
			add_alt($gcf2, "$git_dir/objects");

			if ($gcf2->cat_oid(1, $oid)) {
				warn "I: $$ $oid found after retry\n";
			} else {
				warn "W: $$ $oid missing after retry\n";
				print "$oid missing\n"; # mimic git-cat-file
			}
		}
	}
}

1;
