# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# reader for mbox variants we support
package PublicInbox::MboxReader;
use strict;
use v5.10.1;
use Data::Dumper;
$Data::Dumper::Useqq = 1; # should've been the default, for bad data

my $from_strict =
	qr/^From \S+ +\S+ \S+ +\S+ [^\n:]+:[^\n:]+:[^\n:]+ [^\n:]+\n/sm;

# cf: https://doc.dovecot.org/configuration_manual/mail_location/mbox/
my %status2kw = (F => 'flagged', A => 'answered', R => 'seen', T => 'draft');
# O (old/non-recent), and D (deleted) aren't in JMAP,
# so probably won't be supported by us.
sub mbox_keywords {
	my $eml = $_[-1];
	my $s = "@{[$eml->header_raw('X-Status'),$eml->header_raw('Status')]}";
	my %kw;
	$s =~ s/([FART])/$kw{$status2kw{$1}} = 1/sge;
	[ sort(keys %kw) ];
}

sub _mbox_from {
	my ($mbfh, $from_re, $eml_cb, @arg) = @_;
	my $buf = '';
	my @raw;
	while (defined(my $r = read($mbfh, $buf, 65536, length($buf)))) {
		if ($r == 0) { # close here to check for "curl --fail"
			close($mbfh) or die "error closing mbox: \$?=$? $!";
			@raw = ($buf);
		} else {
			@raw = split(/$from_strict/mos, $buf, -1);
			next if scalar(@raw) == 0;
			$buf = pop(@raw); # last bit may be incomplete
		}
		@raw = grep /[^ \t\r\n]/s, @raw; # skip empty messages
		while (defined(my $raw = shift @raw)) {
			$raw =~ s/^\r?\n\z//ms;
			$raw =~ s/$from_re/$1/gms;
			my $eml = PublicInbox::Eml->new(\$raw);
			$eml_cb->($eml, @arg) if $eml->raw_size;
		}
		return if $r == 0; # EOF
	}
	die "error reading mboxo/mboxrd handle: $!";
}

sub mboxrd {
	my (undef, $mbfh, $eml_cb, @arg) = @_;
	_mbox_from($mbfh, qr/^>(>*From )/ms, $eml_cb, @arg);
}

sub mboxo {
	my (undef, $mbfh, $eml_cb, @arg) = @_;
	_mbox_from($mbfh, qr/^>(From )/ms, $eml_cb, @arg);
}

sub _cl_body {
	my ($mbfh, $bref, $cl) = @_;
	my $body = substr($$bref, 0, $cl, '');
	my $need = $cl - length($body);
	if ($need > 0) {
		$mbfh or die "E: needed $need bytes after EOF";
		defined(my $r = read($mbfh, $body, $need, length($body))) or
			die "E: read error: $!\n";
		$r == $need or die "E: read $r of $need bytes\n";
	}
	\$body;
}

sub _extract_hdr {
	my ($ref) = @_;
	if (index($$ref, "\r\n") < 0 && (my $pos = index($$ref, "\n\n")) >= 0) {
		# likely on *nix
		\substr($$ref, 0, $pos + 2, ''); # sv_chop on $$ref
	} elsif ($$ref =~ /\r?\n\r?\n/s) {
		\substr($$ref, 0, $+[0], ''); # sv_chop on $$ref
	} else {
		undef
	}
}

sub _mbox_cl ($$$;@) {
	my ($mbfh, $uxs_from, $eml_cb, @arg) = @_;
	my $buf = '';
	while (defined(my $r = read($mbfh, $buf, 65536, length($buf)))) {
		if ($r == 0) { # detect "curl --fail"
			close($mbfh) or
				die "error closing mboxcl/mboxcl2: \$?=$? $!";
			undef $mbfh;
		}
		while (my $hdr = _extract_hdr(\$buf)) {
			$$hdr =~ s/\A[\r\n]*From [^\n]*\n//s or
				die "E: no 'From ' line in:\n", Dumper($hdr);
			my $eml = PublicInbox::Eml->new($hdr);
			next unless $eml->raw_size;
			my @cl = $eml->header_raw('Content-Length');
			my $n = scalar(@cl);
			$n == 0 and die "E: Content-Length missing in:\n",
					Dumper($eml->as_string);
			$n == 1 or die "E: multiple ($n) Content-Length in:\n",
					Dumper($eml->as_string);
			$cl[0] =~ /\A[0-9]+\z/ or die
				"E: Content-Length `$cl[0]' invalid\n",
					Dumper($eml->as_string);
			if (($eml->{bdy} = _cl_body($mbfh, \$buf, $cl[0]))) {
				$uxs_from and
					${$eml->{bdy}} =~ s/^>From /From /sgm;
			}
			$eml_cb->($eml, @arg);
		}
		if ($r == 0) {
			$buf =~ /[^ \r\n\t]/ and
				warn "W: leftover at end of mboxcl/mboxcl2:\n",
					Dumper(\$buf);
			return;
		}
	}
	die "error reading mboxcl/mboxcl2 handle: $!";
}

sub mboxcl {
	my (undef, $mbfh, $eml_cb, @arg) = @_;
	_mbox_cl($mbfh, 1, $eml_cb, @arg);
}

sub mboxcl2 {
	my (undef, $mbfh, $eml_cb, @arg) = @_;
	_mbox_cl($mbfh, undef, $eml_cb, @arg);
}

sub new { bless \(my $x), __PACKAGE__ }

sub reads {
	my $ifmt = $_[-1];
	$ifmt =~ /\Ambox(?:rd|cl|cl2|o)\z/ ? __PACKAGE__->can($ifmt) : undef
}

# all of these support -c for stdout and -d for decompression,
# mutt is commonly distributed with hooks for gz, bz2 and xz, at least
# { foo => '' } means "--foo" is passed to the command-line,
# otherwise { foo => '--bar' } passes "--bar"
my %zsfx2cmd = (
	gz => [ qw(GZIP pigz gzip) ],
	bz2 => [ 'bzip2', {} ],
	xz => [ 'xz', {} ],
	# don't add new entries here unless MUA support is widely available
);

sub zsfx ($) {
	my ($pathname) = @_;
	my $allow = join('|', keys %zsfx2cmd);
	$pathname =~ /\.($allow)\z/ ? $1 : undef;
}

sub zsfx2cmd ($$$) {
	my ($zsfx, $decompress, $lei) = @_;
	my $x = $zsfx2cmd{$zsfx} // die "BUG: no support for suffix=.$zsfx";
	my @info = @$x;
	my $cmd_opt = ref($info[-1]) ? pop(@info) : undef;
	my @cmd = (undef, $decompress ? qw(-dc) : qw(-c));
	require PublicInbox::Spawn;
	for my $exe (@info) {
		# I think respecting client's ENV{GZIP} is OK, not sure
		# about ENV overrides for other, less-common compressors
		if ($exe eq uc($exe)) {
			$exe = $lei->{env}->{$exe} or next;
		}
		$cmd[0] = PublicInbox::Spawn::which($exe) and last;
	}
	$cmd[0] // die join(' or ', @info)." missing for .$zsfx";

	# not all gzip support --rsyncable, FreeBSD gzip doesn't even exit
	# with an error code
	if (!$decompress && $cmd[0] =~ m!/gzip\z! && !defined($cmd_opt)) {
		pipe(my ($r, $w)) or die "pipe: $!";
		open my $null, '+>', '/dev/null' or die "open: $!";
		my $rdr = { 0 => $null, 1 => $null, 2 => $w };
		my $tst = [ $cmd[0], '--rsyncable' ];
		my $pid = PublicInbox::Spawn::spawn($tst, undef, $rdr);
		close $w;
		my $err = do { local $/; <$r> };
		waitpid($pid, 0) == $pid or die "BUG: waitpid: $!";
		$cmd_opt = $err ? {} : { rsyncable => '' };
		push(@$x, $cmd_opt);
	}
	for my $bool (keys %$cmd_opt) {
		my $switch = $cmd_opt->{$bool} // next;
		push @cmd, '--'.($switch || $bool);
	}
	for my $key (qw(rsyncable)) { # support compression level?
		my $switch = $cmd_opt->{$key} // next;
		my $val = $lei->{opt}->{$key} // next;
		push @cmd, $switch, $val;
	}
	\@cmd;
}

sub zsfxcat ($$$) {
	my ($in, $zsfx, $lei) = @_;
	my $cmd = zsfx2cmd($zsfx, 1, $lei);
	PublicInbox::Spawn::popen_rd($cmd, undef, { 0 => $in, 2 => $lei->{2} });
}

1;
