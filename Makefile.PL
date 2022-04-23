#!/usr/bin/perl -w
# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use ExtUtils::MakeMaker;
open my $m, '<', 'MANIFEST' or die "open(MANIFEST): $!\n";
chomp(my @manifest = (<$m>));
push @manifest, 'lib/PublicInbox.pm'; # generated
my @EXE_FILES = grep(m!^script/!, @manifest);
my $v = {};
my $t = {};

# do not sort
my @RELEASES = qw(v1.8.0 v1.7.0 v1.6.1 v1.6.0 v1.5.0 v1.4.0 v1.3.0 v1.2.0
	v1.1.0-pre1 v1.0.0);

$v->{news_deps} = [ map { "Documentation/RelNotes/$_.eml" } @RELEASES ];
$v->{txt} = [ qw(INSTALL README COPYING TODO HACKING) ];
my @dtxt = grep(m!\ADocumentation/[^/]+\.txt\z!, @manifest);
push @dtxt, 'Documentation/standards.txt';
push @dtxt, 'Documentation/flow.txt';
push @dtxt, @{$v->{txt}};
for my $txt (@dtxt) {
	my $html = $txt;
	$html =~ s/\.txt\z/.html/ or $html .= '.html';
	$t->{"$html : $txt"} = [ "\$(txt2pre) <$txt", "touch -r $txt \$@" ];
}
$v->{t_slash_star_dot_t} = [ grep(m!\At/.*\.t\z!, @manifest) ];
my @scripts = qw(scripts/ssoma-replay); # legacy
my @syn = (@EXE_FILES, grep(m!^lib/.*\.pm$!, @manifest), @scripts);
@syn = grep(!/DSKQXS\.pm/, @syn) if !eval { require IO::KQueue };
@syn = grep(!/Unsubscribe\.pm/, @syn) if !eval { require Crypt::CBC };
@syn = grep(!/SaPlugin/, @syn) if !eval { require Mail::SpamAssasin };
$v->{syn_files} = \@syn;
$v->{my_syntax} = [map { "$_.syntax" } @syn];
my @no_pod;
$v->{-m1} = [ map {
		my $x = (split('/'))[-1];
		my $pod = "Documentation/$x.pod";
		if (-f $pod) {
			$x;
		} else {
			warn "W: $pod missing\n";
			push @no_pod, $x;
			();
		}
	} @EXE_FILES,
	qw(
	lei-add-external lei-add-watch lei-blob lei-config lei-convert
	lei-daemon-kill lei-daemon-pid lei-edit-search lei-export-kw
	lei-forget-external lei-forget-mail-sync lei-forget-search
	lei-import lei-index lei-init lei-inspect lei-lcat
	lei-ls-external lei-ls-label lei-ls-mail-source lei-ls-mail-sync
	lei-ls-search lei-ls-watch lei-mail-diff lei-p2q lei-q
	lei-rediff lei-refresh-mail-sync lei-rm lei-rm-watch lei-tag
	lei-up)];
$v->{-m5} = [ qw(public-inbox-config public-inbox-v1-format
		public-inbox-v2-format public-inbox-extindex-format
		lei-mail-formats lei-store-format
		) ];
$v->{-m7} = [ qw(lei-mail-sync-overview lei-overview lei-security
		public-inbox-overview public-inbox-tuning
		public-inbox-glossary) ];
$v->{-m8} = [ qw(public-inbox-daemon lei-daemon) ];
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
		$t->{"$txt : $m.$i"} = [ "\$(man2text) ./$m.$i >\$\@+",
					"touch -r $pod \$\@+ ./$m.$i",
					"mv \$\@+ \$@" ];
		$t->{"Documentation/$m.html : $txt"} = [ "\$(txt2pre) <$txt",
							"touch -r $txt \$@" ];
		$t->{".$m.cols : $m.$i"} = [
			"\@echo CHECK80 $m.$i;".
			"COLUMNS=80 \$(MAN) ./$m.$i | \$(check_man)",
			'>$@' ];
		$t->{".$m.lexgrog: $m.$i"} = [
			"\@echo LEXGROG $m.$i;" .
			"\$(LEXGROG) ./$m.$i >\$\@+ && mv \$\@+ \$@" ];
	}
	push @{$v->{check_80}}, map { ".$_.cols" } @$ary;
	push @{$v->{check_lexgrog}}, map { ".$_.lexgrog" } @$ary;
	my $manuals = $v->{"man$i"} = [ map { "$_.$i" } @$ary ];
	push @{$v->{manuals}}, @$manuals;
	push @{$v->{mantxt}}, map { "Documentation/$_.txt" } @$ary;
}
$v->{docs} = [ @dtxt, 'NEWS' ];
$v->{docs_html} = [ map {;
		my $x = $_;
		$x =~ s/\.txt\z//;
		"$x.html"
	} (@{$v->{docs}}, @{$v->{mantxt}}) ];
$v->{gz_docs} = [ map { "$_.gz" } (@{$v->{docs}},@{$v->{docs_html}}) ];
$v->{rsync_docs} = [ @{$v->{gz_docs}}, @{$v->{docs}},
	@{$v->{docs_html}}, qw(NEWS.atom NEWS.atom.gz)];

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
	"lib/PublicInbox/$_" => "blib/man3/PublicInbox::$mod.\$(MAN3EXT)"
} qw(Git.pm Import.pm WWW.pod SaPlugin/ListMirror.pod);
my $warn_no_pod = @no_pod ? "\n\t\@echo W: missing .pod: @no_pod\n" : '';
chomp(my $lexgrog = `which lexgrog 2>/dev/null`);
my $check_lexgrog = $lexgrog ? 'check-lexgrog' : '';

WriteMakefile(
	NAME => 'PublicInbox', # n.b. camel-case is not our choice

	# XXX drop "PENDING" in .pod before updating this!
	VERSION => '1.9.0.PENDING',

	AUTHOR => 'public-inbox hackers <meta@public-inbox.org>',
	ABSTRACT => 'an "archives first" approach to mailing lists',
	EXE_FILES => \@EXE_FILES,

	# DO NOT blindly put "use v5.12" in *.pm files, unicode_strings
	# causes known breakages.  "use v5.10.1" is safe, though
	MIN_PERL_VERSION => '5.12.0',
	LICENSE => 'agpl_3', # AGPL-3.0+, CPAN::Meta::Spec doesn't have '+'
	PREREQ_PM => {
		# note: we use spamc(1), NOT the Perl modules
		# We also depend on git.
		# Keep this sorted and synced to the INSTALL document

		# perl-modules-5.xx or libperl5.xx in Debian-based
		# part of "perl5" on FreeBSD
		'Compress::Raw::Zlib' => 0,
		'Compress::Zlib' => 0,
		'Data::Dumper' => 0,
		'Digest::SHA' => 0, # rpm: perl-Digest-SHA
		'Encode' => 2.35, # 2.35 shipped with 5.10.1
		'IO::Compress::Gzip' => 0,
		'IO::Uncompress::Gunzip' => 0,
		'Storable' => 0, # rpm: perl-Storable
		'Text::ParseWords' => 0, # rpm: perl-Text-ParseWords

		# Plack is needed for public-inbox-httpd and PublicInbox::WWW
		# 'Plack' => 0,

		'URI' => 0,

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
	clean => {
		FILES => 't/home*/setup* t/home*/t* t/home*/.public-inbox '.
			't/data-gen/*'
	},
	PM => {
		map {
			s[^lib/][]s;
			+('lib/' . $_ => '$(INST_LIB)/' . $_);
		} grep {
			# Will include *.pod and an *.h file, but so
			# would ExtUtils::MakeMaker.
			m[^lib/];
		} @manifest
	},
);

sub MY::postamble {
	my $N = (`{ getconf _NPROCESSORS_ONLN || nproc; } 2>/dev/null` || 1);
	$N += 1; # account for sleeps in some tests (and makes an IV)
	<<EOF;
PROVE = prove
# support using eatmydata to speed up tests (apt-get install eatmydata):
# https://www.flamingspork.com/projects/libeatmydata/
EATMYDATA =
N = $N
-include config.mak
$VARS
-include Documentation/include.mk
$TGTS

check-man :: $check_lexgrog$warn_no_pod

# syntax checks are currently GNU make only:
%.syntax :: %
	@\$(PERL) -w -I lib -c \$<

syntax:: \$(my_syntax)

changed = \$(shell git ls-files -m)
dsyn :: \$(addsuffix .syntax, \$(filter \$(changed), \$(syn_files)))

check_manifest := if test -e .git && git ls-files >MANIFEST.gen 2>&1; then \\
		diff -u MANIFEST MANIFEST.gen; fi

check-manifest : MANIFEST
	\$(check_manifest)

# the traditional way running per-*.t processes:
check-each :: pure_all
	\$(EATMYDATA) \$(PROVE) --state=save -bvw -j\$(N)
	-@\$(check_manifest)

# lightly-tested way to run tests, relies "--state=save" in check-each
# for best performance
check-run :: pure_all check-man
	\$(EATMYDATA) \$(PROVE) -bvw t/run.perl :: -j\$(N)
	-@\$(check_manifest)

check :: check-each

lib/PublicInbox/UserContent.pm :: contrib/css/216dark.css
	\$(PERL) -I lib \$@ \$?

# Ensure new .pm files will always be installed by updating
# the timestamp of Makefile.PL which forces Makefile to be remade
Makefile.PL : MANIFEST
	touch -r MANIFEST \$@
	\$(PERLRUN) \$@

# Install symlinks to ~/bin (which is hopefuly in PATH) which point to
# this source tree.
# prefix + bindir matches git.git Makefile:
prefix = \$(HOME)
bindir = \$(prefix)/bin
symlink-install : lib/PublicInbox.pm
	mkdir -p \$(bindir)
	lei=\$\$(realpath lei.sh) && cd \$(bindir) && \\
	for x in \$(EXE_FILES); do \\
		ln -sf "\$\$lei" \$\$(basename "\$\$x"); \\
	done

pure_all :: lib/PublicInbox.pm
lib/PublicInbox.pm : FORCE
	VERSION=\$(VERSION) \$(PERL) -w ./version-gen.perl

update-copyrights :
	\@case '\$(GNULIB_PATH)' in '') echo >&2 GNULIB_PATH unset; false;; esac
	git ls-files | UPDATE_COPYRIGHT_HOLDER='all contributors' \\
		UPDATE_COPYRIGHT_USE_INTERVALS=2 \\
		xargs \$(GNULIB_PATH)/build-aux/update-copyright
EOF
}
