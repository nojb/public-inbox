# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# backend for a git-cat-file-workalike based on libgit2,
# other libgit2 stuff may go here, too.
package PublicInbox::Gcf2;
use strict;
use v5.10.1;
use PublicInbox::Spawn qw(which popen_rd); # may set PERL_INLINE_DIRECTORY
use Fcntl qw(LOCK_EX SEEK_SET);
use IO::Handle; # autoflush
BEGIN {
	my (%CFG, $c_src);
	# PublicInbox::Spawn will set PERL_INLINE_DIRECTORY
	# to ~/.cache/public-inbox/inline-c if it exists
	my $inline_dir = $ENV{PERL_INLINE_DIRECTORY} //
		die 'PERL_INLINE_DIRECTORY not defined';
	my $f = "$inline_dir/.public-inbox.lock";
	open my $fh, '+>', $f or die "open($f): $!";

	# CentOS 7.x ships Inline 0.53, 0.64+ has built-in locking
	flock($fh, LOCK_EX) or die "LOCK_EX($f): $!\n";

	my $pc = which($ENV{PKG_CONFIG} // 'pkg-config') //
		die "pkg-config missing for libgit2";
	my ($dir) = (__FILE__ =~ m!\A(.+?)/[^/]+\z!);
	my $ef = "$inline_dir/.public-inbox.pkg-config.err";
	open my $err, '+>', $ef or die "open($ef): $!";
	for my $x (qw(libgit2)) {
		my $rdr = { 2 => $err };
		my ($l, $pid) = popen_rd([$pc, '--libs', $x], undef, $rdr);
		$l = do { local $/; <$l> };
		waitpid($pid, 0);
		next if $?;
		(my $c, $pid) = popen_rd([$pc, '--cflags', $x], undef, $rdr);
		$c = do { local $/; <$c> };
		waitpid($pid, 0);
		next if $?;

		# note: we name C source files .h to prevent
		# ExtUtils::MakeMaker from automatically trying to
		# build them.
		my $f = "$dir/gcf2_$x.h";
		open(my $src, '<', $f) or die "E: open($f): $!";
		chomp($l, $c);
		local $/;
		defined($c_src = <$src>) or die "read $f: $!";
		$CFG{LIBS} = $l;
		$CFG{CCFLAGSEX} = $c;
		last;
	}
	unless ($c_src) {
		seek($err, 0, SEEK_SET);
		$err = do { local $/; <$err> };
		die "E: libgit2 not installed: $err\n";
	}
	open my $oldout, '>&', \*STDOUT or die "dup(1): $!";
	open my $olderr, '>&', \*STDERR or die "dup(2): $!";
	open STDOUT, '>&', $fh or die "1>$f: $!";
	open STDERR, '>&', $fh or die "2>$f: $!";
	STDERR->autoflush(1);
	STDOUT->autoflush(1);

	# we use Capitalized and ALLCAPS for compatibility with old Inline::C
	eval <<'EOM';
use Inline C => Config => %CFG, BOOT => q[git_libgit2_init();];
use Inline C => $c_src, BUILD_NOISY => 1;
EOM
	$err = $@;
	open(STDERR, '>&', $olderr) or warn "restore stderr: $!";
	open(STDOUT, '>&', $oldout) or warn "restore stdout: $!";
	if ($err) {
		seek($fh, 0, SEEK_SET);
		my @msg = <$fh>;
		die "Inline::C Gcf2 build failed:\n", $err, "\n", @msg;
	}
}

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
	1;
}

# Usage: $^X -MPublicInbox::Gcf2 -e PublicInbox::Gcf2::loop
# (see lib/PublicInbox/Gcf2Client.pm)
sub loop () {
	my $gcf2 = new();
	my %seen;
	STDERR->autoflush(1);
	STDOUT->autoflush(1);

	while (<STDIN>) {
		chomp;
		my ($oid, $git_dir) = split(/ /, $_, 2);
		$seen{$git_dir} //= add_alt($gcf2, "$git_dir/objects");
		if (!$gcf2->cat_oid(1, $oid)) {
			# retry once if missing.  We only get unabbreviated OIDs
			# from SQLite or Xapian DBs, here, so malicious clients
			# can't trigger excessive retries:
			warn "I: $$ $oid missing, retrying in $git_dir\n";

			$gcf2 = new();
			%seen = ($git_dir => add_alt($gcf2,"$git_dir/objects"));

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
