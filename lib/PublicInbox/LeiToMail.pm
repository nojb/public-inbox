# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Writes PublicInbox::Eml objects atomically to a mbox variant or Maildir
package PublicInbox::LeiToMail;
use strict;
use v5.10.1;
use PublicInbox::Eml;

my %kw2char = ( # Maildir characters
	draft => 'D',
	flagged => 'F',
	answered => 'R',
	seen => 'S'
);

my %kw2status = (
	flagged => [ 'X-Status' => 'F' ],
	answered => [ 'X-Status' => 'A' ],
	seen => [ 'Status' => 'R' ],
	draft => [ 'X-Status' => 'T' ],
);

sub _mbox_hdr_buf ($$$) {
	my ($eml, $type, $kw) = @_;
	$eml->header_set($_) for (qw(Lines Bytes Content-Length));
	my %hdr; # set Status, X-Status
	for my $k (@$kw) {
		if (my $ent = $kw2status{$k}) {
			push @{$hdr{$ent->[0]}}, $ent->[1];
		} else { # X-Label?
			warn "TODO: keyword `$k' not supported for mbox\n";
		}
	}
	while (my ($name, $chars) = each %hdr) {
		$eml->header_set($name, join('', sort @$chars));
	}
	my $buf = delete $eml->{hdr};

	# fixup old bug from import (pre-a0c07cba0e5d8b6a)
	$$buf =~ s/\A[\r\n]*From [^\r\n]*\r?\n//s;

	substr($$buf, 0, 0, # prepend From line
		"From lei\@$type Thu Jan  1 00:00:00 1970$eml->{crlf}");
	$buf;
}

sub write_in_full_atomic ($$) {
	my ($fh, $buf) = @_;
	defined(my $w = syswrite($fh, $$buf)) or die "write: $!";
	$w == length($$buf) or die "short write: $w != ".length($$buf);
}

sub eml2mboxrd ($;$) {
	my ($eml, $kw) = @_;
	my $buf = _mbox_hdr_buf($eml, 'mboxrd', $kw);
	if (my $bdy = delete $eml->{bdy}) {
		$$bdy =~ s/^(>*From )/>$1/gm;
		$$buf .= $eml->{crlf};
		substr($$bdy, 0, 0, $$buf); # prepend header
		$buf = $bdy;
	}
	$$buf .= $eml->{crlf};
	$buf;
}

sub eml2mboxo {
	my ($eml, $kw) = @_;
	my $buf = _mbox_hdr_buf($eml, 'mboxo', $kw);
	if (my $bdy = delete $eml->{bdy}) {
		$$bdy =~ s/^From />From /gm;
		$$buf .= $eml->{crlf};
		substr($$bdy, 0, 0, $$buf); # prepend header
		$buf = $bdy;
	}
	$$buf .= $eml->{crlf};
	$buf;
}

# mboxcl still escapes "From " lines
sub eml2mboxcl {
	my ($eml, $kw) = @_;
	my $buf = _mbox_hdr_buf($eml, 'mboxcl', $kw);
	my $crlf = $eml->{crlf};
	if (my $bdy = delete $eml->{bdy}) {
		$$bdy =~ s/^From />From /gm;
		$$buf .= 'Content-Length: '.length($$bdy).$crlf.$crlf;
		substr($$bdy, 0, 0, $$buf); # prepend header
		$buf = $bdy;
	}
	$$buf .= $crlf;
	$buf;
}

# mboxcl2 has no "From " escaping
sub eml2mboxcl2 {
	my ($eml, $kw) = @_;
	my $buf = _mbox_hdr_buf($eml, 'mboxcl2', $kw);
	my $crlf = $eml->{crlf};
	if (my $bdy = delete $eml->{bdy}) {
		$$buf .= 'Content-Length: '.length($$bdy).$crlf.$crlf;
		substr($$bdy, 0, 0, $$buf); # prepend header
		$buf = $bdy;
	}
	$$buf .= $crlf;
	$buf;
}

1;
