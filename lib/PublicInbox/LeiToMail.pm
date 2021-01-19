# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Writes PublicInbox::Eml objects atomically to a mbox variant or Maildir
package PublicInbox::LeiToMail;
use strict;
use v5.10.1;
use parent qw(PublicInbox::IPC);
use PublicInbox::Eml;
use PublicInbox::Lock;
use PublicInbox::ProcessPipe;
use PublicInbox::Spawn qw(which spawn popen_rd);
use PublicInbox::LeiDedupe;
use Symbol qw(gensym);
use IO::Handle; # ->autoflush
use Fcntl qw(SEEK_SET SEEK_END O_CREAT O_EXCL O_WRONLY);
use Errno qw(EEXIST ESPIPE ENOENT);
use PublicInbox::Git;

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

	# Messages are always 'O' (non-\Recent in IMAP), it saves
	# MUAs the trouble of rewriting the mbox if no other
	# changes are made
	my %hdr = (Status => [ 'O' ]); # set Status, X-Status
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

sub _mboxcl_common ($$$) {
	my ($buf, $bdy, $crlf) = @_;
	# add Lines: so mutt won't have to add it on MUA close
	my $lines = $$bdy =~ tr!\n!\n!;
	$$buf .= 'Content-Length: '.length($$bdy).$crlf.
		'Lines: '.$lines.$crlf.$crlf;
	substr($$bdy, 0, 0, $$buf); # prepend header
	$_[0] = $bdy;
}

# mboxcl still escapes "From " lines
sub eml2mboxcl {
	my ($eml, $kw) = @_;
	my $buf = _mbox_hdr_buf($eml, 'mboxcl', $kw);
	my $crlf = $eml->{crlf};
	if (my $bdy = delete $eml->{bdy}) {
		$$bdy =~ s/^From />From /gm;
		_mboxcl_common($buf, $bdy, $crlf);
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
		_mboxcl_common($buf, $bdy, $crlf);
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
	gz => [ qw(GZIP pigz gzip), { rsyncable => '', threads => '-p' } ],
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

sub _post_augment_mbox { # open a compressor process
	my ($self, $lei) = @_;
	my $zsfx = $self->{zsfx} or return;
	my $cmd = zsfx2cmd($zsfx, undef, $lei);
	pipe(my ($r, $w)) or die "pipe: $!";
	my $rdr = { 0 => $r, 1 => $lei->{1}, 2 => $lei->{2} };
	my $pid = spawn($cmd, $lei->{env}, $rdr);
	$lei->{"pid.$pid"} = $cmd;
	my $pp = gensym;
	tie *$pp, 'PublicInbox::ProcessPipe', $pid, $w, \&reap_compress, $lei;
	$lei->{1} = $pp;
	die 'BUG: unexpected {ovv}->{lock_path}' if $lei->{ovv}->{lock_path};
	$lei->{ovv}->ovv_out_lk_init if ($lei->{opt}->{jobs} // 2) > 1;
}

sub decompress_src ($$$) {
	my ($in, $zsfx, $lei) = @_;
	my $cmd = zsfx2cmd($zsfx, 1, $lei);
	popen_rd($cmd, $lei->{env}, { 0 => $in, 2 => $lei->{2} });
}

sub dup_src ($) {
	my ($in) = @_;
	# fileno needed because wq_set_recv_modes only used ">&=" for {1}
	# and Perl blindly trusts that to reject the '+' (readability flag)
	open my $dup, '+>>&=', fileno($in) or die "dup: $!";
	$dup;
}

# --augment existing output destination, with deduplication
sub _augment { # MboxReader eml_cb
	my ($eml, $lei) = @_;
	# ignore return value, just populate the skv
	$lei->{dedupe}->is_dup($eml);
}

sub _mbox_write_cb ($$) {
	my ($self, $lei) = @_;
	my $ovv = $lei->{ovv};
	my $m = 'eml2'.$ovv->{fmt};
	my $eml2mbox = $self->can($m) or die "$self->$m missing";
	my $out = $lei->{1} // die "no stdout ($m, $ovv->{dst})"; # redirected earlier
	$out->autoflush(1);
	my $write = $ovv->{lock_path} ? \&_print_full : \&atomic_append;
	my $dedupe = $lei->{dedupe};
	$dedupe->prepare_dedupe;
	sub { # for git_to_mail
		my ($buf, $oid, $kw) = @_;
		return unless $out;
		my $eml = PublicInbox::Eml->new($buf);
		if (!$dedupe->is_dup($eml, $oid)) {
			$buf = $eml2mbox->($eml, $kw);
			my $lk = $ovv->lock_for_scope;
			eval { $write->($out, $buf) };
			if ($@) {
				die $@ if ref($@) ne 'PublicInbox::SIGPIPE';
				undef $out
			}
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
		# ignore new/ and write only to cur/, otherwise MUAs
		# with R/W access to the Maildir will end up doing
		# a mass rename which can take a while with thousands
		# of messages.
		$dst .= 'cur/';
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
	my ($self, $lei) = @_;
	my $dedupe = $lei->{dedupe};
	$dedupe->prepare_dedupe;
	my $dst = $lei->{ovv}->{dst};
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
	my ($self, $lei) = @_;
	# _mbox_write_cb or _maildir_write_cb
	my $m = "_$self->{base_type}_write_cb";
	$self->$m($lei);
}

sub new {
	my ($cls, $lei) = @_;
	my $fmt = $lei->{ovv}->{fmt};
	my $dst = $lei->{ovv}->{dst};
	my $self = bless {}, $cls;
	if ($fmt eq 'maildir') {
		$self->{base_type} = 'maildir';
		$lei->{ovv}->{dst} = $dst .= '/' if substr($dst, -1) ne '/';
	} elsif (substr($fmt, 0, 4) eq 'mbox') {
		$self->can("eml2$fmt") or die "bad mbox --format=$fmt\n";
		$self->{base_type} = 'mbox';
	} else {
		die "bad mail --format=$fmt\n";
	}
	$lei->{dedupe} = PublicInbox::LeiDedupe->new($lei);
	$self;
}

sub _pre_augment_maildir {} # noop

sub _do_augment_maildir {
	my ($self, $lei) = @_;
	my $dst = $lei->{ovv}->{dst};
	if ($lei->{opt}->{augment}) {
		my $dedupe = $lei->{dedupe};
		if ($dedupe && $dedupe->prepare_dedupe) {
			require PublicInbox::InboxWritable; # eml_from_path
			_maildir_each_file($dst, \&_augment_file, $lei);
			$dedupe->pause_dedupe;
		}
	} else { # clobber existing Maildir
		_maildir_each_file($dst, \&_unlink);
	}
}

sub _post_augment_maildir {
	my ($self, $lei) = @_;
	my $dst = $lei->{ovv}->{dst};
	for my $x (qw(tmp new cur)) {
		my $d = $dst.$x;
		next if -d $d;
		require File::Path;
		File::Path::mkpath($d) or die "mkpath($d): $!";
		-d $d or die "$d is not a directory";
	}
}

sub _pre_augment_mbox {
	my ($self, $lei) = @_;
	my $dst = $lei->{ovv}->{dst};
	if ($dst ne '/dev/stdout') {
		my $mode = -p $dst ? '>' : '+>>';
		if (-f _ && !$lei->{opt}->{augment} and !unlink($dst)) {
			$! == ENOENT or die "unlink($dst): $!";
		}
		open my $out, $mode, $dst or die "open($dst): $!";
		$lei->{1} = $out;
	}
	# Perl does SEEK_END even with O_APPEND :<
	$self->{seekable} = seek($lei->{1}, 0, SEEK_SET);
	if (!$self->{seekable} && $! != ESPIPE && $dst ne '/dev/stdout') {
		die "seek($dst): $!\n";
	}
	state $zsfx_allow = join('|', keys %zsfx2cmd);
	($self->{zsfx}) = ($dst =~ /\.($zsfx_allow)\z/);
}

sub _do_augment_mbox {
	my ($self, $lei) = @_;
	return if !$lei->{opt}->{augment};
	my $dedupe = $lei->{dedupe};
	my $dst = $lei->{ovv}->{dst};
	die "cannot augment $dst, not seekable\n" if !$self->{seekable};
	my $out = $lei->{1};
	if (-s $out && $dedupe && $dedupe->prepare_dedupe) {
		my $zsfx = $self->{zsfx};
		my $rd = $zsfx ? decompress_src($out, $zsfx, $lei) :
				dup_src($out);
		my $fmt = $lei->{ovv}->{fmt};
		require PublicInbox::MboxReader;
		PublicInbox::MboxReader->$fmt($rd, \&_augment, $lei);
	}
	# maybe some systems don't honor O_APPEND, Perl does this:
	seek($out, 0, SEEK_END) or die "seek $dst: $!";
	$dedupe->pause_dedupe if $dedupe;
}

sub pre_augment { # fast (1 disk seek), runs in main daemon
	my ($self, $lei) = @_;
	# _pre_augment_maildir, _pre_augment_mbox
	my $m = "_pre_augment_$self->{base_type}";
	$self->$m($lei);
}

sub do_augment { # slow, runs in wq worker
	my ($self, $lei) = @_;
	# _do_augment_maildir, _do_augment_mbox
	my $m = "_do_augment_$self->{base_type}";
	$self->$m($lei);
}

sub post_augment { # fast (spawn compressor or mkdir), runs in main daemon
	my ($self, $lei) = @_;
	# _post_augment_maildir, _post_augment_mbox
	my $m = "_post_augment_$self->{base_type}";
	$self->$m($lei);
}

sub lock_free {
	$_[0]->{base_type} =~ /\A(?:maildir|mh|imap|jmap)\z/ ? 1 : 0;
}

sub write_mail { # via ->wq_do
	my ($self, $git_dir, $oid, $lei, $kw) = @_;
	my $not_done = delete $self->{4}; # write end of {each_smsg_done}
	my $wcb = $self->{wcb} //= do { # first message
		my %sig = $lei->atfork_child_wq($self);
		@SIG{keys %sig} = values %sig; # not local
		$lei->{dedupe}->prepare_dedupe;
		$self->write_cb($lei);
	};
	my $git = $self->{"$$\0$git_dir"} //= PublicInbox::Git->new($git_dir);
	$git->cat_async($oid, \&git_to_mail, [ $wcb, $kw, $not_done ]);
}

sub ipc_atfork_prepare {
	my ($self) = @_;
	# (qry_status_wr, stdout|mbox, stderr, 3: sock, 4: each_smsg_done_wr)
	$self->wq_set_recv_modes(qw[+<&= >&= >&= +<&= >&=]);
	$self->SUPER::ipc_atfork_prepare; # PublicInbox::IPC
}

sub DESTROY {
	my ($self) = @_;
	for my $pid_git (grep(/\A$$\0/, keys %$self)) {
		$self->{$pid_git}->async_wait_all;
	}
}

1;
