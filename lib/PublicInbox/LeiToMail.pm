# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Writes PublicInbox::Eml objects atomically to a mbox variant or Maildir
package PublicInbox::LeiToMail;
use strict;
use v5.10.1;
use PublicInbox::Eml;
use PublicInbox::Lock;
use PublicInbox::ProcessPipe;
use PublicInbox::SharedKV;
use PublicInbox::Spawn qw(which spawn popen_rd);
use PublicInbox::ContentHash qw(content_hash);
use Symbol qw(gensym);
use IO::Handle; # ->autoflush
use Fcntl qw(SEEK_SET);

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

# all of these support -c for stdout and -d for decompression,
# mutt is commonly distributed with hooks for gz, bz2 and xz, at least
# { foo => '' } means "--foo" is passed to the command-line,
# otherwise { foo => '--bar' } passes "--bar"
our %zsfx2cmd = (
	gz => [ qw(GZIP pigz gzip), {
		rsyncable => '', threads => '-p' } ],
	bz2 => [ 'bzip2', {} ],
	xz => [ 'xz', { threads => '-T' } ],
	# XXX does anybody care for these?  I prefer zstd on entire FSes,
	# so it's probably not necessary on a per-file basis
	# zst => [ 'zstd', { -default => [ qw(-q) ], # it's noisy by default
	#	rsyncable => '', threads => '-T' } ],
	# zz => [ 'pigz', { -default => [ '--zlib' ],
	#	rsyncable => '', threads => '-p' }],
	# lzo => [ 'lzop', {} ],
	# lzma => [ 'lzma', {} ],
);

sub zsfx2cmd ($$$) {
	my ($zsfx, $decompress, $lei) = @_;
	my $x = $zsfx2cmd{$zsfx} // die "no support for suffix=.$zsfx";
	my @info = @$x;
	my $cmd_opt = pop @info;
	my @cmd = (undef, $decompress ? qw(-dc) : qw(-c));
	for my $exe (@info) {
		# I think respecting client's ENV{GZIP} is OK, not sure
		# about ENV overrides for other, less-common compressors
		if ($exe eq uc($exe)) {
			$exe = $lei->{env}->{$exe} or next;
		}
		$cmd[0] = which($exe) and last;
	}
	$cmd[0] // die join(' or ', @info)." missing for .$zsfx";
	# push @cmd, @{$cmd_opt->{-default}} if $cmd_opt->{-default};
	for my $bool (qw(rsyncable)) {
		my $switch = $cmd_opt->{rsyncable} // next;
		push @cmd, '--'.($switch || $bool);
	}
	for my $key (qw(threads)) { # support compression level?
		my $switch = $cmd_opt->{$key} // next;
		my $val = $lei->{opt}->{$key} // next;
		push @cmd, $switch, $val;
	}
	\@cmd;
}

sub compress_dst {
	my ($out, $zsfx, $lei) = @_;
	my $cmd = zsfx2cmd($zsfx, undef, $lei);
	pipe(my ($r, $w)) or die "pipe: $!";
	my $rdr = { 0 => $r, 1 => $out, 2 => $lei->{2} };
	my $pid = spawn($cmd, $lei->{env}, $rdr);
	$lei->{"pid.$pid"} = $cmd;
	my $pp = gensym;
	tie *$pp, 'PublicInbox::ProcessPipe', $pid, $w, \&reap_compress, $lei;
	my $pipe_lk = ($lei->{opt}->{jobs} // 0) > 1 ?
			PublicInbox::Lock->new_tmp($zsfx) : undef;
	($pp, $pipe_lk);
}

sub decompress_src ($$$) {
	my ($in, $zsfx, $lei) = @_;
	my $cmd = zsfx2cmd($zsfx, 1, $lei);
	my $rdr = { 0 => $in, 2 => $lei->{2} };
	popen_rd($cmd, $lei->{env}, $rdr);
}

sub dup_src ($) {
	my ($in) = @_;
	open my $dup, '+>>&', $in or die "dup: $!";
	$dup;
}

# --augment existing output destination, without duplicating anything
sub _augment { # MboxReader eml_cb
	my ($eml, $lei) = @_;
	$lei->{skv}->set_maybe(content_hash($eml), '');
}

sub _mbox_write_cb ($$$$) {
	my ($cls, $mbox, $dst, $lei) = @_;
	my $m = "eml2$mbox";
	my $eml2mbox = $cls->can($m) or die "$cls->$m missing";
	my ($out, $pipe_lk);
	open $out, '+>>', $dst or die "open $dst: $!";
	# Perl does SEEK_END even with O_APPEND :<
	seek($out, 0, SEEK_SET) or die "seek $dst: $!";
	my $atomic = !!(($lei->{opt}->{jobs} // 0) > 1);
	$lei->{skv} = PublicInbox::SharedKV->new;
	$lei->{skv}->dbh;
	state $zsfx_allow = join('|', keys %zsfx2cmd);
	my ($zsfx) = ($dst =~ /\.($zsfx_allow)\z/);
	if ($lei->{opt}->{augment}) {
		my $rd = $zsfx ? decompress_src($out, $zsfx, $lei) :
				dup_src($out);
		PublicInbox::MboxReader->$mbox($rd, \&_augment, $lei);
	} else {
		truncate($out, 0) or die "truncate $dst: $!";
	}
	($out, $pipe_lk) = compress_dst($out, $zsfx, $lei) if $zsfx;
	sub {
		my ($buf, $oid, $kw) = @_;
		my $eml = PublicInbox::Eml->new($buf);
		if ($lei->{skv}->set_maybe(content_hash($eml), '')) {
			$buf = $eml2mbox->($eml, $kw);
			my $lock = $pipe_lk->lock_for_scope if $pipe_lk;
			write_in_full($out, $buf, $atomic);
		}
	}
}

sub write_cb { # returns a callback for git_to_mail
	my ($cls, $dst, $lei) = @_;
	if ($dst =~ s!\A(mbox(?:rd|cl|cl2|o))?:!!) {
		_mbox_write_cb($cls, $1, $dst, $lei);
	}
}

1;
