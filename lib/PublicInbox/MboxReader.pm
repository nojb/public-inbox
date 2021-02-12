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
			$eml_cb->($eml, @arg);
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

1;
