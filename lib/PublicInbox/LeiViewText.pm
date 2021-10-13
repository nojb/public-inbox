# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# PublicInbox::Eml to (optionally colorized) text coverter for terminals
# the non-HTML counterpart to PublicInbox::View
package PublicInbox::LeiViewText;
use strict;
use v5.10.1;
use PublicInbox::MsgIter qw(msg_part_text);
use PublicInbox::MID qw(references);
use PublicInbox::View;
use PublicInbox::Hval;
use PublicInbox::ViewDiff;
use PublicInbox::Spawn qw(popen_rd);
use Term::ANSIColor;
use POSIX ();
use PublicInbox::Address;

sub _xs {
	# xhtml_map works since we don't search for HTML ([&<>'"])
	$_[0] =~ s/([\x7f\x00-\x1f])/$PublicInbox::Hval::xhtml_map{$1}/sge;
}

my %DEFAULT_COLOR = (
	# mutt names, loaded from ~/.config/lei/config
	quoted => 'blue',
	hdrdefault => 'cyan',
	status => 'bright_cyan', # smsg stuff
	attachment => 'bright_red',

	# git names and defaults, falls back to ~/.gitconfig
	new => 'green',
	old => 'red',
	meta => 'bold',
	frag => 'cyan',
	func => undef,
	context => undef,
);

my $COLOR = qr/(?:bright)?
		(?:normal|black|red|green|yellow|blue|magenta|cyan|white)/x;

sub my_colored {
	my ($self, $slot, $buf) = @_;
	my $val = $self->{"color.$slot"} //=
			$self->{-leicfg}->{"color.$slot"} //
			$self->{-gitcfg}->{"color.diff.$slot"} //
			$self->{-gitcfg}->{"diff.color.$slot"} //
			$DEFAULT_COLOR{$slot};
	$val = $val->[-1] if ref($val) eq 'ARRAY';
	if (defined $val) {
		$val = lc $val;
		# git doesn't use "_", Term::ANSIColor does
		$val =~ s/\Abright([^_])/bright_$1/ig;

		# git: "green black" => T::A: "green on_black"
		$val =~ s/($COLOR)(.+?)($COLOR)/$1$2on_$3/;

		# FIXME: convert git #XXXXXX to T::A-compatible colors
		# for 256-color terminals

		${$self->{obuf}} .= colored($buf, $val);
	} else {
		${$self->{obuf}} .= $buf;
	}
}

sub uncolored { ${$_[0]->{obuf}} .= $_[2] }

sub new {
	my ($cls, $lei, $fmt) = @_;
	my $self = bless { %{$lei->{opt}}, -colored => \&uncolored }, $cls;
	$self->{-quote_reply} = 1 if $fmt eq 'reply';
	return $self unless $self->{color} //= -t $lei->{1};
	my $cmd = [ qw(git config -z --includes -l) ];
	my ($r, $pid) = popen_rd($cmd, undef, { 2 => $lei->{2} });
	my $cfg = PublicInbox::Config::config_fh_parse($r, "\0", "\n");
	waitpid($pid, 0);
	if ($?) {
		warn "# git-config failed, no color (non-fatal)\n";
		return $self;
	}
	$self->{-colored} = \&my_colored;
	$self->{-gitcfg} = $cfg;
	$self->{-leicfg} = $lei->{cfg};
	$self;
}

sub quote_hdr_buf ($$) {
	my ($self, $eml) = @_;
	my $hbuf = '';
	my $to = $eml->header_raw('Reply-To') //
		$eml->header_raw('From') //
		$eml->header_raw('Sender');
	my $cc = '';
	for my $f (qw(To Cc)) {
		for my $v ($eml->header_raw($f)) {
			next if $v !~ /\S/;
			$cc .= ", $v";
			$to //= $v;
		}
	}
	substr($cc, 0, 2, ''); # s/^, //;
	PublicInbox::View::fold_addresses($to);
	PublicInbox::View::fold_addresses($cc);
	_xs($to);
	_xs($cc);
	$hbuf .= "To: $to\n" if defined $to && $to =~ /\S/;
	$hbuf .= "Cc: $cc\n" if $cc =~ /\S/;
	my $s = $eml->header_str('Subject') // 'your mail';
	_xs($s);
	substr($s, 0, 0, 'Re: ') if $s !~ /\bRe:/i;
	$hbuf .= "Subject: $s\n";
	if (defined(my $irt = $eml->header_raw('Message-ID'))) {
		_xs($irt);
		$hbuf .= "In-Reply-To: $irt\n";
	}
	$self->{-colored}->($self, 'hdrdefault', $hbuf);
	my ($n) = PublicInbox::Address::names($eml->header_str('From') //
					$eml->header_str('Sender') //
					$eml->header_str('Reply-To') //
					'unknown sender');
	my $d = $eml->header_raw('Date') // 'some unknown date';
	_xs($d);
	_xs($n);
	${delete $self->{obuf}} . "\nOn $d, $n wrote:\n";
}

sub hdr_buf ($$) {
	my ($self, $eml) = @_;
	my $hbuf = '';
	for my $f (qw(From To Cc)) {
		for my $v ($eml->header($f)) {
			next if $v !~ /\S/;
			PublicInbox::View::fold_addresses($v);
			_xs($v);
			$hbuf .= "$f: $v\n";
		}
	}
	for my $f (qw(Subject Date Newsgroups Message-ID X-Message-ID)) {
		for my $v ($eml->header($f)) {
			_xs($v);
			$hbuf .= "$f: $v\n";
		}
	}
	if (my @irt = $eml->header_raw('In-Reply-To')) {
		for my $v (@irt) {
			_xs($v);
			$hbuf .= "In-Reply-To: $v\n";
		}
	} else {
		my $refs = references($eml);
		if (defined(my $irt = pop @$refs)) {
			_xs($irt);
			$hbuf .= "In-Reply-To: <$irt>\n";
		}
		if (@$refs) {
			my $max = $self->{-max_cols};
			$hbuf .= 'References: ' .
				join("\n\t", map { '<'._xs($_).'>' } @$refs) .
				">\n";
		}
	}
	$self->{-colored}->($self, 'hdrdefault', $hbuf .= "\n");
}

sub attach_note ($$$$;$) {
	my ($self, $ct, $p, $fn, $err) = @_;
	my ($part, $depth, $idx) = @$p;
	my $nl = $idx eq '1' ? '' : "\n"; # like join("\n", ...)
	my $abuf = $err ? <<EOF : '';
[-- Warning: decoded text below may be mangled, UTF-8 assumed --]
EOF
	$abuf .= "[-- Attachment #$idx: ";
	_xs($ct);
	my $size = length($part->body);
	my $ts = "Type: $ct, Size: $size bytes";
	my $d = $part->header('Content-Description') // $fn // '';
	_xs($d);
	$abuf .= $d eq '' ? "$ts --]\n" : "$d --]\n[-- $ts --]\n";
	if (my $blob = $self->{-smsg}->{blob}) {
		$abuf .= "[-- lei blob $blob:$idx --]\n";
	}
	$self->{-colored}->($self, 'attachment', $abuf);
	hdr_buf($self, $part) if $part->{is_submsg};
}

sub flush_text_diff ($$) {
	my ($self, $cur) = @_;
	my @top = split($PublicInbox::ViewDiff::EXTRACT_DIFFS, $$cur);
	undef $$cur; # free memory
	my $dctx;
	my $obuf = $self->{obuf};
	my $colored = $self->{-colored};
	while (defined(my $x = shift @top)) {
		if (scalar(@top) >= 4 &&
				$top[1] =~ $PublicInbox::ViewDiff::IS_OID &&
				$top[0] =~ $PublicInbox::ViewDiff::IS_OID) {
			splice(@top, 0, 4);
			$dctx = 1;
			$colored->($self, 'meta', $x);
		} elsif ($dctx) {
			# Quiet "Complex regular subexpression recursion limit"
			# warning.  Perl will truncate matches upon hitting
			# that limit, giving us more (and shorter) scalars than
			# would be ideal, but otherwise it's harmless.
			#
			# We could replace the `+' metacharacter with `{1,100}'
			# to limit the matches ourselves to 100, but we can
			# let Perl do it for us, quietly.
			no warnings 'regexp';

			for my $s (split(/((?:(?:^\+[^\n]*\n)+)|
					(?:(?:^-[^\n]*\n)+)|
					(?:^@@ [^\n]+\n))/xsm, $x)) {
				if (!defined($dctx)) {
					${$self->{obuf}} .= $s;
				} elsif ($s =~ s/\A(@@ \S+ \S+ @@\s*)//) {
					$colored->($self, 'frag', $1);
					$colored->($self, 'func', $s);
				} elsif ($s =~ /\A\+/) {
					$colored->($self, 'new', $s);
				} elsif ($s =~ /\A-- $/sm) { # email sig starts
					$dctx = undef;
					${$self->{obuf}} .= $s;
				} elsif ($s =~ /\A-/) {
					$colored->($self, 'old', $s);
				} else {
					$colored->($self, 'context', $s);
				}
			}
		} else {
			${$self->{obuf}} .= $x;
		}
	}
}

sub add_text_buf { # callback for Eml->each_part
	my ($p, $self) = @_;
	my ($part, $depth, $idx) = @$p;
	my $ct = $part->content_type || 'text/plain';
	my $fn = $part->filename;
	my ($s, $err) = msg_part_text($part, $ct);
	return attach_note($self, $ct, $p, $fn) unless defined $s;
	hdr_buf($self, $part) if $part->{is_submsg};
	$s =~ s/\r\n/\n/sg;
	_xs($s);
	my $diff = ($s =~ /^--- [^\n]+\n\+{3} [^\n]+\n@@ /ms);
	my @sections = PublicInbox::MsgIter::split_quotes($s);
	undef $s; # free memory
	if (defined($fn) || ($depth > 0 && !$part->{is_submsg}) || $err) {
		# badly-encoded message with $err? tell the world about it!
		attach_note($self, $ct, $p, $fn, $err);
		${$self->{obuf}} .= "\n";
	}
	my $colored = $self->{-colored};
	for my $cur (@sections) {
		if ($cur =~ /\A>/) {
			$colored->($self, 'quoted', $cur);
		} elsif ($diff) {
			flush_text_diff($self, \$cur);
		} else {
			${$self->{obuf}} .= $cur;
		}
		undef $cur; # free memory
	}
}

# returns a stringref suitable for $lei->out or print
sub eml_to_text {
	my ($self, $smsg, $eml) = @_;
	local $Term::ANSIColor::EACHLINE = "\n";
	$self->{obuf} = \(my $obuf = '');
	$self->{-smsg} = $smsg;
	$self->{-max_cols} = ($self->{columns} //= 80) - 8; # for header wrap
	my $h = [];
	if ($self->{-quote_reply}) {
		my $blob = $smsg->{blob} // 'unknown-blob';
		my $pct = $smsg->{pct} // 'unknown';
		my $t = POSIX::asctime(gmtime($smsg->{ts} // $smsg->{ds} // 0));
		$h->[0] = "From $blob\@$pct $t";
	} else {
		for my $f (qw(blob pct)) {
			push @$h, "$f:$smsg->{$f}" if defined $smsg->{$f};
		}
		@$h = ("# @$h\n") if @$h;
		for my $f (qw(kw L)) {
			my $v = $smsg->{$f} or next;
			push @$h, "# $f:".join(',', @$v)."\n" if @$v;
		}
	}
	$h = join('', @$h);
	$self->{-colored}->($self, 'status', $h);
	my $quote_hdr;
	if ($self->{-quote_reply}) {
		$quote_hdr = ${delete $self->{obuf}};
		$quote_hdr .= quote_hdr_buf($self, $eml);
	} else {
		hdr_buf($self, $eml);
	}
	$eml->each_part(\&add_text_buf, $self, 1);
	if (defined $quote_hdr) {
		${$self->{obuf}} =~ s/^/> /sgm;
		substr(${$self->{obuf}}, 0, 0, $quote_hdr);
	}
	delete $self->{obuf};
}

1;
