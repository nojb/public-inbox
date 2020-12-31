# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Writes PublicInbox::Eml objects atomically to a mbox variant or Maildir
package PublicInbox::LeiToMail;
use strict;
use v5.10.1;
use PublicInbox::Eml;
use PublicInbox::Lock;
use PublicInbox::ProcessPipe;
use PublicInbox::Spawn qw(which spawn);
use Symbol qw(gensym);
use File::Temp ();
use IO::Handle; # ->autoflush

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

sub write_in_full ($$$) {
	my ($fh, $buf, $atomic) = @_;
	if ($atomic) {
		defined(my $w = syswrite($fh, $$buf)) or die "write: $!";
		$w == length($$buf) or die "short write: $w != ".length($$buf);
	} else {
		print $fh $$buf or die "print: $!";
	}
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

sub mkmaildir ($) {
	my ($maildir) = @_;
	for (qw(new tmp cur)) {
		my $d = "$maildir/$_";
		next if -d $d;
		require File::Path;
		if (!File::Path::mkpath($d) && !-d $d) {
			die "failed to mkpath($d): $!\n";
		}
	}
}

sub git_to_mail { # git->cat_async callback
	my ($bref, $oid, $type, $size, $arg) = @_;
	if ($type ne 'blob') {
		if ($type eq 'missing') {
			warn "missing $oid\n";
		} else {
			warn "unexpected type=$type for $oid\n";
		}
	}
	if ($size > 0) {
		my ($write_cb, $kw) = @$arg;
		$write_cb->($bref, $oid, $kw);
	}
}

sub reap_compress { # dwaitpid callback
	my ($lei, $pid) = @_;
	my $cmd = delete $lei->{"pid.$pid"};
	return if $? == 0;
	$lei->fail("@$cmd failed", $? >> 8);
}

sub compress_dst {
	my ($out, $sfx, $lei) = @_;
	my $cmd = [];
	if ($sfx eq 'gz') {
		$cmd->[0] = which($lei->{env}->{GZIP} // 'pigz') //
				which('gzip') //
			die "pigz or gzip missing for $sfx\n";
			# TODO: use IO::Compress::Gzip
		push @$cmd, '-c'; # stdout
		push @$cmd, '--rsyncable' if $lei->{opt}->{rsyncable};
	} else {
		die "TODO $sfx"
	}
	pipe(my ($r, $w)) or die "pipe: $!";
	my $rdr = { 0 => $r, 1 => $out, 2 => $lei->{2} };
	my $pid = spawn($cmd, $lei->{env}, $rdr);
	$lei->{"pid.$pid"} = $cmd;
	my $pp = gensym;
	tie *$pp, 'PublicInbox::ProcessPipe', $pid, $w, \&reap_compress, $lei;
	my $tmp = File::Temp->new("$sfx.lock-XXXXXX", TMPDIR => 1);
	my $pipe_lk = ($lei->{opt}->{jobs} // 0) > 1 ? bless({
		lock_path => $tmp->filename,
		tmp => $tmp
	}, 'PublicInbox::Lock') : undef;
	($pp, $pipe_lk);
}

sub write_cb {
	my ($cls, $dst, $lei) = @_;
	if ($dst =~ s!\A(mbox(?:rd|cl|cl2|o))?:!!) {
		my $m = "eml2$1";
		my $eml2mbox = $cls->can($m) or die "$cls->$m missing";
		my ($out, $pipe_lk);
		open $out, '>>', $dst or die "open $dst: $!";
		my $atomic = !!(($lei->{opt}->{jobs} // 0) > 1);
		if ($dst =~ /\.(gz|bz2|xz)\z/) {
			($out, $pipe_lk) = compress_dst($out, $1, $lei);
		}
		sub {
			my ($buf, $oid, $kw) = @_;
			$buf = $eml2mbox->(PublicInbox::Eml->new($buf), $kw);
			my $lock = $pipe_lk->lock_for_scope if $pipe_lk;
			write_in_full($out, $buf, $atomic);
		}
	}
}

1;
