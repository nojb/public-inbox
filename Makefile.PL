#!/usr/bin/perl -w
# Copyright (C) 2013-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use ExtUtils::MakeMaker;
open my $m, '<', 'MANIFEST' or die "open(MANIFEST): $!\n";
chomp(my @manifest = (<$m>));
my @EXE_FILES = grep(m!^script/!, @manifest);
my $v = {};
my $t = {};
my @RELEASES = qw(v1.4.0 v1.3.0 v1.2.0 v1.1.0-pre1 v1.0.0); # do not sort
$v->{news_deps} = [ map { "Documentation/RelNotes/$_.eml" } @RELEASES ];
$v->{txt} = [ qw(INSTALL README COPYING TODO HACKING) ];
my @dtxt = grep(m!\ADocumentation/[^/]+\.txt\z!, @manifest);
push @dtxt, 'Documentation/standards.txt';
push @dtxt, 'Documentation/flow.txt';
push @dtxt, @{$v->{txt}};
for my $txt (@dtxt) {
	my $html = $txt;
	$html =~ s/\.txt\z/.html/ or $html .= '.html';
	$t->{"$html : $txt"} = [ "\$(txt2pre) <$txt" ];
}
$v->{t_slash_star_dot_t} = [ grep(m!\At/.*\.t\z!, @manifest) ];
my @scripts = qw(scripts/ssoma-replay); # legacy
my @syn = (@EXE_FILES, grep(m!^lib/.*\.pm$!, @manifest), @scripts);
@syn = grep(!/DSKQXS\.pm/, @syn) if !eval { require IO::KQueue };
@syn = grep(!/Unsubscribe\.pm/, @syn) if !eval { require Crypt::CBC };
@syn = grep(!/SaPlugin/, @syn) if !eval { require Mail::SpamAssasin };
$v->{syn_files} = \@syn;
$v->{my_syntax} = [map { "$_.syntax" } @syn];
$v->{-m1} = [ map { (split('/'))[-1] } @EXE_FILES ];
$v->{-m5} = [ qw(public-inbox-config public-inbox-v1-format
		public-inbox-v2-format) ];
$v->{-m7} = [ qw(public-inbox-overview) ];
$v->{-m8} = [ qw(public-inbox-daemon) ];
my @sections = (1, 5, 7, 8);
$v->{check_80} = [];
$v->{manuals} = [];
$v->{mantxt} = [];
for my $i (@sections) {
	my $ary = $v->{"-m$i"};
	$v->{"m$i"} = $ary;
	for my $m (@$ary) {
		my $pod = "Documentation/$m.pod";
		my $txt = "Documentation/$m.txt";
		$t->{"$m.$i : $pod"} = [ "\$(podman) -s$i $pod \$@" ];
		$t->{"$txt : $pod"} = [ "\$(podtext) $pod \$\@+",
					"touch -r $pod \$\@+",
					"mv \$\@+ \$@" ];
		$t->{"Documentation/$m.html : $txt"} = [ "\$(txt2pre) <$txt" ];
		$t->{".$m.cols : $m.$i"} = [
			"\@echo CHECK80 $m.$i;".
			"COLUMNS=80 \$(MAN) ./$m.$i | \$(check_man)" ];
	}
	push @{$v->{check_80}}, map { ".$_.cols" } @$ary;
	my $manuals = $v->{"man$i"} = [ map { "$_.$i" } @$ary ];
	push @{$v->{manuals}}, @$manuals;
	push @{$v->{mantxt}}, map { "Documentation/$_.txt" } @$ary;
}
push @dtxt, @{$v->{mantxt}};
$v->{docs} = [ @dtxt, 'NEWS' ];
$v->{docs_html} = [ map {;
		my $x = $_;
		$x =~ s/\.txt\z//;
		"$x.html"
	} @{$v->{docs}} ];
$v->{gz_docs} = [ map { "$_.gz" } (@{$v->{docs}},@{$v->{docs_html}}) ];
$v->{rsync_docs} = [ @{$v->{gz_docs}}, @{$v->{docs}},
	@{$v->{docs_html}}, qw(NEWS.atom NEWS.atom.gz)];

# external manpages which we host ourselves, since some packages
# (currently just Xapian) doesn't host manpages themselves.
my @xman = qw(copydatabase.1 xapian-compact.1);
$v->{xdocs} = [ map { "Documentation/.$_.txt" } @xman ];
$v->{xdocs_html} = [ map { "Documentation/.$_.html" } @xman ];
for (@{$v->{xdocs}}) {
	$t->{"$_:"} = [
		'$(PERL) -w Documentation/extman.perl $@ >$@+',
		'mv $@+ $@'
	];
	my $html = $_;
	$html =~ s/\.txt\z/.html/;
	$t->{"$html : $_"} = [ "\$(txt2pre) <$_" ];
}
$v->{gz_xdocs} = [ map { "$_.gz" } (@{$v->{xdocs_html}}, @{$v->{xdocs}}) ];
$v->{rsync_xdocs} = [ @{$v->{gz_xdocs}}, @{$v->{xdocs_html}}, @{$v->{xdocs}} ];

my $TGTS = join("\n", map {;
	my $tgt_prereq = $_;
	my $cmds = $t->{$_};
	"$tgt_prereq\n".join('', map { "\t$_\n" } @$cmds);
} sort keys %$t);

my $VARS = join("\n", map {;
	my $varname = $_;
	join('', map { "$varname += $_\n" } sort @{$v->{$varname}});
} grep(!/^-/, sort keys %$v));
$VARS .= "\nRELEASES = ".join(' ', @RELEASES)."\n";

# Don't waste user's disk space by installing some pods from
# imported code or internal use only
my %man3 = map {; # semi-colon tells Perl this is a BLOCK (and not EXPR)
	my $base = $_;
	my $mod = $base;
	$mod =~ s!/!::!g;
	$mod =~ s/\.\w+\z//;
	"lib/PublicInbox/$_" => "blib/man3/PublicInbox::$mod.3"
} qw(Git.pm Import.pm WWW.pod SaPlugin/ListMirror.pod);

WriteMakefile(
	NAME => 'PublicInbox',
	VERSION => '1.4.0',
	AUTHOR => 'Eric Wong <e@yhbt.net>',
	ABSTRACT => 'public-inbox server infrastructure',
	EXE_FILES => \@EXE_FILES,
	PREREQ_PM => {
		# note: we use spamc(1), NOT the Perl modules
		# We also depend on git.
		# Keep this sorted and synced to the INSTALL document

		# libperl$PERL_VERSION,
		# `perl5' on FreeBSD
		# perl-Digest-SHA on RH-based
		'Digest::SHA' => 0,
		'Email::MIME' => 0,

		# the following should be pulled in by Email::MIME:
		'Email::MIME::ContentType' => 0,
		'Email::Simple' => 0,

		# libperl$PERL_VERSION or libencode-perl on Debian,
		# `perl5' on FreeBSD
		'Encode' => 2.35, # 2.35 shipped with 5.10.1

		# libperl$PERL_VERSION + perl-modules-$PERL_VERSION
		'Compress::Raw::Zlib' => 0,
		'Compress::Zlib' => 0,
		'IO::Compress::Gzip' => 0,

		# Plack is needed for public-inbox-httpd and PublicInbox::WWW
		# 'Plack' => 0,

		# Filesys::Notify::Simple is pulled in by Plack, but also
		# needed by public-inbox-watch (for now)
		# 'Filesys::Notify::Simple' => 0,

		# TODO: this should really be made optional...
		'URI::Escape' => 0,

		# We have more test dependencies, but do not force
		# users to install them.  See INSTALL

		# All Perl installs I know about have these, but RH-based
		# distros make them separate even though 'perl' pulls them in
		'File::Path' => 0,
		'File::Temp' => '0.19', # for ->tmpdir support
		'Getopt::Long' => 0,
		'Exporter' => 0,
		# ExtUtils::MakeMaker # this file won't run w/o it...
	},
	MAN3PODS => \%man3,
);

sub MY::postamble {
  <<EOF;
PROVE = prove
# support using eatmydata to speed up tests (apt-get install eatmydata):
# https://www.flamingspork.com/projects/libeatmydata/
EATMYDATA =
N = \$\$(( \$\$(nproc 2>/dev/null || gnproc 2>/dev/null || echo 2) + 1 ))
-include config.mak
$VARS
-include Documentation/include.mk
$TGTS

# syntax checks are currently GNU make only:
%.syntax :: %
	@\$(PERL) -w -I lib -c \$<

syntax:: \$(my_syntax)

changed = \$(shell git ls-files -m)
dsyn :: \$(addsuffix .syntax, \$(filter \$(changed), \$(syn_files)))

check-manifest :: MANIFEST
	if test -e .git && git ls-files >\$?.gen 2>&1; then \\
		diff -u \$? \$?.gen; fi

# the traditional way running per-*.t processes:
check-each :: pure_all check-manifest
	\$(EATMYDATA) \$(PROVE) --state=save -bvw -j\$(N)

# lightly-tested way to run tests, relies "--state=save" in check-each
# for best performance
check-run :: pure_all check-manifest
	\$(EATMYDATA) \$(PROVE) -bvw t/run.perl :: -j\$(N)

check :: check-each

lib/PublicInbox/UserContent.pm :: contrib/css/216dark.css
	\$(PERL) -I lib \$@ \$?

# Ensure new .pm files will always be installed by updating
# the timestamp of Makefile.PL which forces Makefile to be remade
Makefile.PL : MANIFEST
	touch -r MANIFEST \$@
	\$(PERLRUN) \$@

EOF
}
