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
use PublicInbox::Git;
use PublicInbox::GitAsyncCat;
use PublicInbox::PktOp qw(pkt_do);
use Symbol qw(gensym);
use IO::Handle; # ->autoflush
use Fcntl qw(SEEK_SET SEEK_END O_CREAT O_EXCL O_WRONLY);
use Errno qw(EEXIST ESPIPE ENOENT EPIPE);
use Digest::SHA qw(sha256_hex);

# struggles with short-lived repos, Gcf2Client makes little sense with lei;
# but we may use in-process libgit2 in the future.
$PublicInbox::GitAsyncCat::GCF2C = 0;

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
	my ($eml, $type, $smsg) = @_;
	$eml->header_set($_) for (qw(Lines Bytes Content-Length));

	# Messages are always 'O' (non-\Recent in IMAP), it saves
	# MUAs the trouble of rewriting the mbox if no other
	# changes are made
	my %hdr = (Status => [ 'O' ]); # set Status, X-Status
	for my $k (@{$smsg->{kw} // []}) {
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
	my $ident = $smsg->{blob} // 'lei';
	if (defined(my $pct = $smsg->{pct})) { $ident .= "=$pct" }

	substr($$buf, 0, 0, # prepend From line
		"From $ident\@$type Thu Jan  1 00:00:00 1970$eml->{crlf}");
	$buf;
}

sub atomic_append { # for on-disk destinations (O_APPEND, or O_EXCL)
	my ($lei, $buf) = @_;
	if (defined(my $w = syswrite($lei->{1} // return, $$buf))) {
		return if $w == length($$buf);
		$buf = "short atomic write: $w != ".length($$buf);
	} elsif ($! == EPIPE) {
		return $lei->note_sigpipe(1);
	} else {
		$buf = "atomic write: $!";
	}
	$lei->fail($buf);
}

sub eml2mboxrd ($;$) {
	my ($eml, $smsg) = @_;
	my $buf = _mbox_hdr_buf($eml, 'mboxrd', $smsg);
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
	my ($eml, $smsg) = @_;
	my $buf = _mbox_hdr_buf($eml, 'mboxo', $smsg);
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
	my ($eml, $smsg) = @_;
	my $buf = _mbox_hdr_buf($eml, 'mboxcl', $smsg);
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
	my ($eml, $smsg) = @_;
	my $buf = _mbox_hdr_buf($eml, 'mboxcl2', $smsg);
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
	my ($write_cb, $smsg) = @$arg;
	if ($smsg->{blob} ne $oid) {
		die "BUG: expected=$smsg->{blob} got=$oid";
	}
	$write_cb->($bref, $smsg) if $size > 0;
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
	my ($r, $w) = @{delete $lei->{zpipe}};
	my $rdr = { 0 => $r, 1 => $lei->{1}, 2 => $lei->{2} };
	my $pid = spawn($cmd, undef, $rdr);
	my $pp = gensym;
	my $dup = bless { "pid.$pid" => $cmd }, ref($lei);
	$dup->{$_} = $lei->{$_} for qw(2 sock);
	tie *$pp, 'PublicInbox::ProcessPipe', $pid, $w, \&reap_compress, $dup;
	$lei->{1} = $pp;
	die 'BUG: unexpected {ovv}->{lock_path}' if $lei->{ovv}->{lock_path};
	$lei->{ovv}->ovv_out_lk_init;
}

sub decompress_src ($$$) {
	my ($in, $zsfx, $lei) = @_;
	my $cmd = zsfx2cmd($zsfx, 1, $lei);
	popen_rd($cmd, undef, { 0 => $in, 2 => $lei->{2} });
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

sub _mbox_augment_kw_maybe {
	my ($eml, $lei, $lse, $augment) = @_;
	my @kw = PublicInbox::LeiStore::mbox_keywords($eml);
	update_kw_maybe($lei, $lse, $eml, \@kw);
	_augment($eml, $lei) if $augment;
}

sub _mbox_write_cb ($$) {
	my ($self, $lei) = @_;
	my $ovv = $lei->{ovv};
	my $m = 'eml2'.$ovv->{fmt};
	my $eml2mbox = $self->can($m) or die "$self->$m missing";
	$lei->{1} // die "no stdout ($m, $ovv->{dst})"; # redirected earlier
	$lei->{1}->autoflush(1);
	my $atomic_append = !defined($ovv->{lock_path});
	my $dedupe = $lei->{dedupe};
	$dedupe->prepare_dedupe;
	sub { # for git_to_mail
		my ($buf, $smsg, $eml) = @_;
		$eml //= PublicInbox::Eml->new($buf);
		return if $dedupe->is_dup($eml, $smsg->{blob});
		$buf = $eml2mbox->($eml, $smsg);
		return atomic_append($lei, $buf) if $atomic_append;
		my $lk = $ovv->lock_for_scope;
		$lei->out($$buf);
	}
}

sub update_kw_maybe ($$$$) {
	my ($lei, $lse, $eml, $kw) = @_;
	return unless $lse;
	my $x = $lse->kw_changed($eml, $kw);
	if ($x) {
		$lei->{sto}->ipc_do('set_eml', $eml, @$kw);
	} elsif (!defined($x)) {
		# TODO: xkw
	}
}

sub _augment_or_unlink { # maildir_each_eml cb
	my ($f, $kw, $eml, $lei, $lse, $mod, $shard, $unlink) = @_;
	if ($mod) {
		# can't get dirent.d_ino w/ pure Perl, so we extract the OID
		# if it looks like one:
		my $hex = $f =~ m!\b([a-f0-9]{40,})[^/]*\z! ?
				$1 : sha256_hex($f);
		my $recno = hex(substr($hex, 0, 8));
		return if ($recno % $mod) != $shard;
		update_kw_maybe($lei, $lse, $eml, $kw);
	}
	$unlink ? unlink($f) : _augment($eml, $lei);
}

# maildir_each_file callback, \&CORE::unlink doesn't work with it
sub _unlink { unlink($_[0]) }

sub _rand () {
	state $seq = 0;
	sprintf('%x,%x,%x,%x', rand(0xffffffff), time, $$, ++$seq);
}

sub _buf2maildir {
	my ($dst, $buf, $smsg) = @_;
	my $kw = $smsg->{kw} // [];
	my $sfx = join('', sort(map { $kw2char{$_} // () } @$kw));
	my $rand = ''; # chosen by die roll :P
	my ($tmp, $fh, $final, $ok);
	my $common = $smsg->{blob} // _rand;
	if (defined(my $pct = $smsg->{pct})) { $common .= "=$pct" }
	do {
		$tmp = $dst.'tmp/'.$rand.$common;
	} while (!($ok = sysopen($fh, $tmp, O_CREAT|O_EXCL|O_WRONLY)) &&
		$! == EEXIST && ($rand = _rand.','));
	if ($ok && print $fh $$buf and close($fh)) {
		# ignore new/ and write only to cur/, otherwise MUAs
		# with R/W access to the Maildir will end up doing
		# a mass rename which can take a while with thousands
		# of messages.
		$dst .= 'cur/';
		$rand = '';
		do {
			$final = $dst.$rand.$common.':2,'.$sfx;
		} while (!($ok = link($tmp, $final)) && $! == EEXIST &&
			($rand = _rand.','));
		die "link($tmp, $final): $!" unless $ok;
		unlink($tmp) or warn "W: failed to unlink $tmp: $!\n";
	} else {
		my $err = "Error writing $smsg->{blob} to $dst: $!\n";
		$_[0] = undef; # clobber dst
		unlink($tmp);
		die $err;
	}
}

sub _maildir_write_cb ($$) {
	my ($self, $lei) = @_;
	my $dedupe = $lei->{dedupe};
	$dedupe->prepare_dedupe if $dedupe;
	my $dst = $lei->{ovv}->{dst};
	sub { # for git_to_mail
		my ($buf, $smsg, $eml) = @_;
		$dst // return $lei->fail; # dst may be undef-ed in last run
		$buf //= \($eml->as_string);
		return _buf2maildir($dst, $buf, $smsg) if !$dedupe;
		$eml //= PublicInbox::Eml->new($$buf); # copy buf
		return if $dedupe->is_dup($eml, $smsg->{blob});
		undef $eml;
		_buf2maildir($dst, $buf, $smsg);
	}
}

sub _imap_write_cb ($$) {
	my ($self, $lei) = @_;
	my $dedupe = $lei->{dedupe};
	$dedupe->prepare_dedupe if $dedupe;
	my $imap_append = $lei->{net}->can('imap_append');
	my $mic = $lei->{net}->mic_get($self->{uri});
	my $folder = $self->{uri}->mailbox;
	sub { # for git_to_mail
		my ($bref, $smsg, $eml) = @_;
		$mic // return $lei->fail; # dst may be undef-ed in last run
		if ($dedupe) {
			$eml //= PublicInbox::Eml->new($$bref); # copy bref
			return if $dedupe->is_dup($eml, $smsg->{blob});
		}
		eval { $imap_append->($mic, $folder, $bref, $smsg, $eml) };
		if (my $err = $@) {
			undef $mic;
			die $err;
		}
	}
}

sub write_cb { # returns a callback for git_to_mail
	my ($self, $lei) = @_;
	# _mbox_write_cb, _maildir_write_cb or _imap_write_cb
	my $m = "_$self->{base_type}_write_cb";
	$self->$m($lei);
}

sub new {
	my ($cls, $lei) = @_;
	my $fmt = $lei->{ovv}->{fmt};
	my $dst = $lei->{ovv}->{dst};
	my $self = bless {}, $cls;
	if ($fmt eq 'maildir') {
		require PublicInbox::MdirReader;
		$self->{base_type} = 'maildir';
		-e $dst && !-d _ and die
				"$dst exists and is not a directory\n";
		$lei->{ovv}->{dst} = $dst .= '/' if substr($dst, -1) ne '/';
	} elsif (substr($fmt, 0, 4) eq 'mbox') {
		require PublicInbox::MboxReader;
		(-d $dst || (-e _ && !-w _)) and die
			"$dst exists and is not a writable file\n";
		$self->can("eml2$fmt") or die "bad mbox format: $fmt\n";
		$self->{base_type} = 'mbox';
	} elsif ($fmt =~ /\Aimaps?\z/) { # TODO .onion support
		require PublicInbox::NetWriter;
		my $net = PublicInbox::NetWriter->new;
		$net->add_url($dst);
		$net->{quiet} = $lei->{opt}->{quiet};
		my $err = $net->errors($dst);
		return $lei->fail($err) if $err;
		require PublicInbox::URIimap; # TODO: URI cast early
		$self->{uri} = PublicInbox::URIimap->new($dst);
		$self->{uri}->mailbox or die "No mailbox: $dst";
		$lei->{net} = $net;
		$self->{base_type} = 'imap';
	} else {
		die "bad mail --format=$fmt\n";
	}
	$self->{dst} = $dst;
	$lei->{dedupe} = PublicInbox::LeiDedupe->new($lei);
	$self;
}

sub _pre_augment_maildir {
	my ($self, $lei) = @_;
	my $dst = $lei->{ovv}->{dst};
	for my $x (qw(tmp new cur)) {
		my $d = $dst.$x;
		next if -d $d;
		require File::Path;
		File::Path::mkpath($d);
		-d $d or die "$d is not a directory";
	}
}

sub _do_augment_maildir {
	my ($self, $lei) = @_;
	my $dst = $lei->{ovv}->{dst};
	my $lse = $lei->{sto}->search if $lei->{opt}->{'import-before'};
	my ($mod, $shard) = @{$self->{shard_info} // []};
	if ($lei->{opt}->{augment}) {
		my $dedupe = $lei->{dedupe};
		if ($dedupe && $dedupe->prepare_dedupe) {
			PublicInbox::MdirReader::maildir_each_eml($dst,
						\&_augment_or_unlink,
						$lei, $lse, $mod, $shard);
			$dedupe->pause_dedupe;
		}
	} elsif ($lse) {
		PublicInbox::MdirReader::maildir_each_eml($dst,
					\&_augment_or_unlink,
					$lei, $lse, $mod, $shard, 1);
	} else {# clobber existing Maildir
		PublicInbox::MdirReader::maildir_each_file($dst, \&_unlink);
	}
}

sub _imap_augment_or_delete { # PublicInbox::NetReader::imap_each cb
	my ($url, $uid, $kw, $eml, $lei, $lse, $delete_mic) = @_;
	update_kw_maybe($lei, $lse, $eml, $kw);
	if ($delete_mic) {
		$lei->{net}->imap_delete_1($url, $uid, $delete_mic);
	} else {
		_augment($eml, $lei);
	}
}

sub _do_augment_imap {
	my ($self, $lei) = @_;
	my $net = $lei->{net};
	my $lse = $lei->{sto}->search if $lei->{opt}->{'import-before'};
	if ($lei->{opt}->{augment}) {
		my $dedupe = $lei->{dedupe};
		if ($dedupe && $dedupe->prepare_dedupe) {
			$net->imap_each($self->{uri}, \&_imap_augment_or_delete,
					$lei, $lse);
			$dedupe->pause_dedupe;
		}
	} elsif ($lse) {
		my $delete_mic;
		$net->imap_each($self->{uri}, \&_imap_augment_or_delete,
					$lei, $lse, \$delete_mic);
		$delete_mic->expunge if $delete_mic;
	} elsif (!$self->{-wq_worker_nr}) { # undef or 0
		# clobber existing IMAP folder
		$net->imap_delete_all($self->{uri});
	}
}

sub _pre_augment_mbox {
	my ($self, $lei) = @_;
	my $dst = $lei->{ovv}->{dst};
	my $out = $lei->{1};
	if ($dst ne '/dev/stdout') {
		if (-p $dst) {
			open $out, '>', $dst or die "open($dst): $!";
		} elsif (-f _ || !-e _) {
			require PublicInbox::MboxLock;
			my $m = $lei->{opt}->{'lock'} //
					PublicInbox::MboxLock->defaults;
			$self->{mbl} = PublicInbox::MboxLock->acq($dst, 1, $m);
			$out = $self->{mbl}->{fh};
		}
		$lei->{old_1} = $lei->{1}; # keep for spawning MUA
	}
	# Perl does SEEK_END even with O_APPEND :<
	$self->{seekable} = seek($out, 0, SEEK_SET);
	if (!$self->{seekable} && $! != ESPIPE && $dst ne '/dev/stdout') {
		die "seek($dst): $!\n";
	}
	if (!$self->{seekable}) {
		my $ia = $lei->{opt}->{'import-before'};
		die "--import-before specified but $dst is not seekable\n"
			if $ia && !ref($ia);
		die "--augment specified but $dst is not seekable\n" if
			$lei->{opt}->{augment};
	}
	state $zsfx_allow = join('|', keys %zsfx2cmd);
	if (($self->{zsfx}) = ($dst =~ /\.($zsfx_allow)\z/)) {
		pipe(my ($r, $w)) or die "pipe: $!";
		$lei->{zpipe} = [ $r, $w ];
	}
	$lei->{1} = $out;
	undef;
}

sub _do_augment_mbox {
	my ($self, $lei) = @_;
	return unless $self->{seekable};
	my $opt = $lei->{opt};
	my $out = $lei->{1};
	my ($fmt, $dst) = @{$lei->{ovv}}{qw(fmt dst)};
	return unless -s $out;
	unless ($opt->{augment} || $opt->{'import-before'}) {
		truncate($out, 0) or die "truncate($dst): $!";
		return;
	}
	my $zsfx = $self->{zsfx};
	my $rd = $zsfx ? decompress_src($out, $zsfx, $lei) : dup_src($out);
	my $dedupe;
	if ($opt->{augment}) {
		$dedupe = $lei->{dedupe};
		$dedupe->prepare_dedupe if $dedupe;
	}
	if ($opt->{'import-before'}) { # the default
		my $lse = $lei->{sto}->search;
		PublicInbox::MboxReader->$fmt($rd, \&_mbox_augment_kw_maybe,
						$lei, $lse, $opt->{augment});
		if (!$opt->{augment} and !truncate($out, 0)) {
			die "truncate($dst): $!";
		}
	} else { # --augment --no-import-before
		PublicInbox::MboxReader->$fmt($rd, \&_augment, $lei);
	}
	# maybe some systems don't honor O_APPEND, Perl does this:
	seek($out, 0, SEEK_END) or die "seek $dst: $!";
	$dedupe->pause_dedupe if $dedupe;
}

sub pre_augment { # fast (1 disk seek), runs in same process as post_augment
	my ($self, $lei) = @_;
	# _pre_augment_maildir, _pre_augment_mbox
	my $m = $self->can("_pre_augment_$self->{base_type}") or return;
	$m->($self, $lei);
}

sub do_augment { # slow, runs in wq worker
	my ($self, $lei) = @_;
	# _do_augment_maildir, _do_augment_mbox, or _do_augment_imap
	my $m = "_do_augment_$self->{base_type}";
	$self->$m($lei);
}

# fast (spawn compressor or mkdir), runs in same process as pre_augment
sub post_augment {
	my ($self, $lei, @args) = @_;
	my $wait = $lei->{opt}->{'import-before'} ?
			$lei->{sto}->ipc_do('checkpoint', 1) : 0;
	# _post_augment_mbox
	my $m = $self->can("_post_augment_$self->{base_type}") or return;
	$m->($self, $lei, @args);
}

sub do_post_auth {
	my ($self) = @_;
	my $lei = $self->{lei};
	# lei_xsearch can start as soon as all l2m workers get here
	pkt_do($lei->{pkt_op_p}, 'incr_start_query') or
		die "incr_start_query: $!";
	my $aug;
	if (lock_free($self)) {
		my $mod = $self->{-wq_nr_workers};
		my $shard = $self->{-wq_worker_nr};
		if (my $net = $lei->{net}) {
			$net->{shard_info} = [ $mod, $shard ];
		} else { # Maildir (MH?)
			$self->{shard_info} = [ $mod, $shard ];
		}
		$aug = '+'; # incr_post_augment
	} elsif ($self->{-wq_worker_nr} == 0) {
		$aug = '.'; # do_post_augment
	}
	if ($aug) {
		local $0 = 'do_augment';
		eval { do_augment($self, $lei) };
		$lei->fail($@) if $@;
		pkt_do($lei->{pkt_op_p}, $aug) == 1 or
				die "do_post_augment trigger: $!";
	}
	if (my $zpipe = delete $lei->{zpipe}) {
		$lei->{1} = $zpipe->[1];
		close $zpipe->[0];
	}
	$self->{wcb} = $self->write_cb($lei);
}

sub ipc_atfork_child {
	my ($self) = @_;
	my $lei = $self->{lei};
	$lei->lei_atfork_child;
	$lei->{auth}->do_auth_atfork($self) if $lei->{auth};
	$SIG{__WARN__} = PublicInbox::Eml::warn_ignore_cb();
	$self->SUPER::ipc_atfork_child;
}

sub lock_free {
	$_[0]->{base_type} =~ /\A(?:maildir|mh|imap|jmap)\z/ ? 1 : 0;
}

sub poke_dst {
	my ($self) = @_;
	if ($self->{base_type} eq 'maildir') {
		my $t = time + 1;
		utime($t, $t, "$self->{dst}/cur");
	}
}

sub write_mail { # via ->wq_io_do
	my ($self, $git_dir, $smsg) = @_;
	my $git = $self->{"$$\0$git_dir"} //= PublicInbox::Git->new($git_dir);
	git_async_cat($git, $smsg->{blob}, \&git_to_mail,
				[$self->{wcb}, $smsg]);
}

sub wq_atexit_child {
	my ($self) = @_;
	delete $self->{wcb};
	for my $git (delete @$self{grep(/\A$$\0/, keys %$self)}) {
		$git->async_wait_all;
	}
	$SIG{__WARN__} = 'DEFAULT';
}

# called in top-level lei-daemon when LeiAuth is done
sub net_merge_complete {
	my ($self) = @_;
	$self->wq_broadcast('do_post_auth');
	$self->wq_close(1);
}

no warnings 'once'; # the following works even when LeiAuth is lazy-loaded
*net_merge_all = \&PublicInbox::LeiAuth::net_merge_all;
1;
