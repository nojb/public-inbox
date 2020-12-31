# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Writes PublicInbox::Eml objects atomically to a mbox variant or Maildir
package PublicInbox::LeiToMail;
use strict;
use v5.10.1;
use PublicInbox::Eml;
use PublicInbox::Lock;
use PublicInbox::ProcessPipe;
use PublicInbox::Spawn qw(which spawn popen_rd);
use PublicInbox::LeiDedupe;
use Symbol qw(gensym);
use IO::Handle; # ->autoflush
use Fcntl qw(SEEK_SET SEEK_END O_CREAT O_EXCL O_WRONLY);
use Errno qw(EEXIST ESPIPE ENOENT);

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

sub atomic_append { # for on-disk destinations (O_APPEND, or O_EXCL)
	my ($fh, $buf) = @_;
	defined(my $w = syswrite($fh, $$buf)) or die "write: $!";
	$w == length($$buf) or die "short write: $w != ".length($$buf);
}

sub _print_full {
	my ($fh, $buf) = @_;
	print $fh $$buf or die "print: $!";
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

# --augment existing output destination, with deduplication
sub _augment { # MboxReader eml_cb
	my ($eml, $lei) = @_;
	# ignore return value, just populate the skv
	$lei->{dedupe}->is_dup($eml);
}

sub _mbox_write_cb ($$$$) {
	my ($cls, $mbox, $dst, $lei) = @_;
	my $m = "eml2$mbox";
	my $eml2mbox = $cls->can($m) or die "$cls->$m missing";
	my ($out, $pipe_lk, $seekable);
	# XXX should we support /dev/stdout.gz ?
	if ($dst eq '/dev/stdout') {
		$out = $lei->{1};
	} else { # TODO: mbox locking (but mairix doesn't...)
		my $mode = -p $dst ? '>' : '+>>';
		if (-f _ && !$lei->{opt}->{augment} and !unlink($dst)) {
			die "unlink $dst: $!" if $! != ENOENT;
		}
		open $out, $mode, $dst or die "open $dst: $!";
		# Perl does SEEK_END even with O_APPEND :<
		$seekable = seek($out, 0, SEEK_SET);
		die "seek $dst: $!\n" if !$seekable && $! != ESPIPE;
	}
	my $jobs = $lei->{opt}->{jobs} // 0;
	state $zsfx_allow = join('|', keys %zsfx2cmd);
	my ($zsfx) = ($dst =~ /\.($zsfx_allow)\z/);
	my $write = $jobs > 1 && !$zsfx ? \&atomic_append : \&_print_full;
	my $dedupe = $lei->{dedupe} = PublicInbox::LeiDedupe->new($lei);
	if ($lei->{opt}->{augment}) {
		die "cannot augment $dst, not seekable\n" if !$seekable;
		if (-s $out && $dedupe->prepare_dedupe) {
			my $rd = $zsfx ? decompress_src($out, $zsfx, $lei) :
					dup_src($out);
			PublicInbox::MboxReader->$mbox($rd, \&_augment, $lei);
		}
		# maybe some systems don't honor O_APPEND, Perl does this:
		seek($out, 0, SEEK_END) or die "seek $dst: $!";
		$dedupe->pause_dedupe if $jobs; # are we forking?
	}
	$dedupe->prepare_dedupe if !$jobs;
	($out, $pipe_lk) = compress_dst($out, $zsfx, $lei) if $zsfx;
	sub { # for git_to_mail
		my ($buf, $oid, $kw) = @_;
		my $eml = PublicInbox::Eml->new($buf);
		if (!$dedupe->is_dup($eml, $oid)) {
			$buf = $eml2mbox->($eml, $kw);
			my $lock = $pipe_lk->lock_for_scope if $pipe_lk;
			$write->($out, $buf);
		}
	}
}

sub _maildir_each_file ($$;@) {
	my ($dir, $cb, @arg) = @_;
	for my $d (qw(new/ cur/)) {
		my $pfx = $dir.$d;
		opendir my $dh, $pfx or next;
		while (defined(my $fn = readdir($dh))) {
			$cb->($pfx.$fn, @arg) if $fn =~ /:2,[A-Za-z]*\z/;
		}
	}
}

sub _augment_file { # _maildir_each_file cb
	my ($f, $lei) = @_;
	my $eml = PublicInbox::InboxWritable::eml_from_path($f) or return;
	_augment($eml, $lei);
}

# _maildir_each_file callback, \&CORE::unlink doesn't work with it
sub _unlink { unlink($_[0]) }

sub _buf2maildir {
	my ($dst, $buf, $oid, $kw) = @_;
	my $sfx = join('', sort(map { $kw2char{$_} // () } @$kw));
	my $rand = ''; # chosen by die roll :P
	my ($tmp, $fh, $final);
	do {
		$tmp = $dst.'tmp/'.$rand."oid=$oid";
	} while (!sysopen($fh, $tmp, O_CREAT|O_EXCL|O_WRONLY) &&
		$! == EEXIST && ($rand = int(rand 0x7fffffff).','));
	if (print $fh $$buf and close($fh)) {
		$dst .= $sfx eq '' ? 'new/' : 'cur/';
		$rand = '';
		do {
			$final = $dst.$rand."oid=$oid:2,$sfx";
		} while (!link($tmp, $final) && $! == EEXIST &&
			($rand = int(rand 0x7fffffff).','));
		unlink($tmp) or warn "W: failed to unlink $tmp: $!\n";
	} else {
		my $err = $!;
		unlink($tmp);
		die "Error writing $oid to $dst: $err";
	}
}


sub _maildir_write_cb ($$) {
	my ($dst, $lei) = @_;
	$dst .= '/' unless substr($dst, -1) eq '/';
	my $dedupe = $lei->{dedupe} = PublicInbox::LeiDedupe->new($lei, $dst);
	my $jobs = $lei->{opt}->{jobs} // 0;
	if ($lei->{opt}->{augment}) {
		if ($dedupe && $dedupe->prepare_dedupe) {
			require PublicInbox::InboxWritable; # eml_from_path
			_maildir_each_file($dst, \&_augment_file, $lei);
			$dedupe->pause_dedupe if $jobs; # are we forking?
		}
	} else { # clobber existing Maildir
		_maildir_each_file($dst, \&_unlink);
	}
	for my $x (qw(tmp new cur)) {
		my $d = $dst.$x;
		next if -d $d;
		require File::Path;
		if (!File::Path::mkpath($d) && !-d $d) {
			die "failed to mkpath($d): $!\n";
		}
	}
	$dedupe->prepare_dedupe if $dedupe && !$jobs;
	sub { # for git_to_mail
		my ($buf, $oid, $kw) = @_;
		return _buf2maildir($dst, $buf, $oid, $kw) if !$dedupe;
		my $eml = PublicInbox::Eml->new($$buf); # copy buf
		return if $dedupe->is_dup($eml, $oid);
		undef $eml;
		_buf2maildir($dst, $buf, $oid, $kw);
	}
}

sub write_cb { # returns a callback for git_to_mail
	my ($cls, $dst, $lei) = @_;
	require PublicInbox::LeiDedupe;
	if ($dst =~ s!\A(mbox(?:rd|cl|cl2|o))?:!!) {
		_mbox_write_cb($cls, $1, $dst, $lei);
	} elsif ($dst =~ s!\A[Mm]aildir:!!) { # typically capitalized
		_maildir_write_cb($dst, $lei);
	}
	# TODO: Maildir, MH, IMAP, JMAP ...
}

1;
