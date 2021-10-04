# Copyright (C) 2019-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# I have no idea how stable or safe this is for handling untrusted
# input, but it seems to have been around for a while, and the
# highlight(1) executable is supported by gitweb and cgit.
#
# I'm also unsure about API stability, but highlight 3.x seems to
# have been around a few years and ikiwiki (apparently the only
# user of the SWIG/Perl bindings, at least in Debian) hasn't needed
# major changes to support it in recent years.
#
# Some code stolen from ikiwiki (GPL-2.0+)
# wrapper for SWIG-generated highlight.pm bindings
package PublicInbox::HlMod;
use strict;
use v5.10.1;
use highlight; # SWIG-generated stuff
use PublicInbox::Hval qw(src_escape ascii_html);
my $hl;

sub _parse_filetypes ($) {
	my $ft_conf = $_[0]->getFiletypesConfPath('filetypes') or
				die 'filetypes.conf not found by highlight';
	open my $fh, '<', $ft_conf or die "failed to open($ft_conf): $!";
	local $/;
	my $cfg = <$fh>;
	my %ext2lang;
	my @shebang; # order matters

	# Hrm... why isn't this exposed by the highlight API?
	# highlight >= 3.2 format (bind-style) (from ikiwiki)
	while ($cfg =~ /\bLang\s*=\s*\"([^"]+)\"[,\s]+
			 Extensions\s*=\s*{([^}]+)}/sgx) {
		my $lang = $1;
		foreach my $bit (split(/,/, $2)) {
			$bit =~ s/.*"(.*)".*/$1/s;
			$ext2lang{$bit} = $lang;
		}
	}
	# AFAIK, all the regexps used by in filetypes.conf distributed
	# by highlight work as Perl REs
	while ($cfg =~ /\bLang\s*=\s*\"([^"]+)\"[,\s]+
			Shebang\s*=\s*\[\s*\[([^}]+)\s*\]\s*\]\s*}\s*,/sgx) {
		my ($lang, $re) = ($1, $2);
		eval {
			my $perl_re = qr/$re/;
			push @shebang, [ $lang, $perl_re ];
		};
		if ($@) {
			warn "$lang shebang=[[$re]] did not work in Perl: $@";
		}
	}
	(\%ext2lang, \@shebang);
}

# We only need one instance
sub new {
	my ($class) = @_;
	$hl ||= do {
		my $dir = highlight::DataDir->new;
		$dir->initSearchDirectories('');
		my ($ext2lang, $shebang) = _parse_filetypes($dir);
		bless {
			-dir => $dir,
			-ext2lang => $ext2lang,
			-shebang => $shebang,
		}, $class;
	};
}

sub _shebang2lang ($$) {
	my ($self, $str) = @_;
	my $shebang = $self->{-shebang};
	foreach my $s (@$shebang) {
		return $s->[0] if $$str =~ $s->[1];
	}
	undef;
}

sub _path2lang ($$) {
	my ($self, $path) = @_;
	my ($ext) = ($path =~ m!([^\\/\.]+)\z!);
	$ext = lc($ext);
	$self->{-ext2lang}->{$ext} || $ext;
}

sub do_hl {
	my ($self, $str, $path) = @_;
	my $lang = _path2lang($self, $path) if defined $path;
	do_hl_lang($self, $str, $lang);
}

sub do_hl_lang {
	my ($self, $str, $lang) = @_;

	my $langpath;
	if (defined $lang) {
		$langpath = $self->{-dir}->getLangPath("$lang.lang") or return;
		undef $lang unless -f $langpath;
	}
	$lang //= _shebang2lang($self, $str) // return;
	$langpath = $self->{-dir}->getLangPath("$lang.lang") or return;
	return unless -f $langpath;

	my $g = highlight::CodeGenerator::getInstance($highlight::HTML);
	$g->setFragmentCode(1); # generate html fragment

	# whatever theme works
	$g->initTheme($self->{-dir}->getThemePath('print.theme'));
	$g->loadLanguage($langpath);
	$g->setEncoding('utf-8');
	# we assume $$str is valid UTF-8, but the SWIG binding doesn't
	# know that, so ensure it's marked as UTF-8 even if it isnt...
	my $out = $g->generateString($$str);
	highlight::CodeGenerator::deleteInstance($g);
	utf8::decode($out);
	src_escape($out);
	\$out;
}

# Highlight text, but support Markdown "```$LANG" notation
# while preserving WYSIWYG of plain-text documentation.
# This is NOT to be enabled by default or encouraged for parsing
# emails, since it is NOT stable and can lead to standards
# proliferation of email.
sub do_hl_text {
	my ($self, $str) = @_;

	$$str = join('', map {
		if (/\A(``` ?)(\w+)\s*?\n(.+)(^```\s*)\z/sm) {
			my ($pfx, $lang, $code, $post) = ($1, $2, $3, $4);
			my $hl = do_hl_lang($self, \$code, $lang) || \$code;
			$pfx . $lang . "\n" . $$hl . $post;
		} else {
			ascii_html($_);
		}
	} split(/(^``` ?\w+\s*?\n.+?^```\s*$)/sm, $$str));
}

1;
