# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# backend for public-inbox-gcf2(1) (git-cat-file based on libgit2,
# other libgit2 stuff may go here, too)
package PublicInbox::Gcf2;
use strict;
use PublicInbox::Spawn qw(which popen_rd);
use Fcntl qw(LOCK_EX);
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
			$c_src = <$fh>;
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
1;
