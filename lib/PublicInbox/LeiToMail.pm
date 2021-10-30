# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Writes PublicInbox::Eml objects atomically to a mbox variant or Maildir
package PublicInbox::LeiToMail;
use strict;
use v5.10.1;
use parent qw(PublicInbox::IPC);
use PublicInbox::Eml;
use PublicInbox::ProcessPipe;
use PublicInbox::Spawn qw(spawn);
use Symbol qw(gensym);
use IO::Handle; # ->autoflush
use Fcntl qw(SEEK_SET SEEK_END O_CREAT O_EXCL O_WRONLY);
use PublicInbox::Syscall qw(rename_noreplace);

my %kw2char = ( # Maildir characters
	draft => 'D',
	flagged => 'F',
	forwarded => 'P', # passed
	answered => 'R',
	seen => 'S',
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

	my %hdr = (Status => []); # set Status, X-Status
	for my $k (@{$smsg->{kw} // []}) {
		if (my $ent = $kw2status{$k}) {
			push @{$hdr{$ent->[0]}}, $ent->[1];
		} else { # X-Label?
			warn "# keyword `$k' not supported for mbox\n";
		}
	}
	# When writing to empty mboxes, messages are always 'O'
	# (not-\Recent in IMAP), it saves MUAs the trouble of
	# rewriting the mbox if no other changes are made.
	# We put 'O' at the end (e.g. "Status: RO") to match mutt(1) output.
	# We only set smsg->{-recent} if augmenting existing stores.
	my $status = join('', sort(@{$hdr{Status}}));
	$status .= 'O' unless $smsg->{-recent};
	$eml->header_set('Status', $status) if $status;
	if (my $chars = delete $hdr{'X-Status'}) {
		$eml->header_set('X-Status', join('', sort(@$chars)));
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
	} elsif ($!{EPIPE}) {
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
	$$bdy .= $crlf;
	$bdy;
}

# mboxcl still escapes "From " lines
sub eml2mboxcl {
	my ($eml, $smsg) = @_;
	my $buf = _mbox_hdr_buf($eml, 'mboxcl', $smsg);
	my $bdy = delete($eml->{bdy}) // \(my $empty = '');
	$$bdy =~ s/^From />From /gm;
	_mboxcl_common($buf, $bdy, $eml->{crlf});
}

# mboxcl2 has no "From " escaping
sub eml2mboxcl2 {
	my ($eml, $smsg) = @_;
	my $buf = _mbox_hdr_buf($eml, 'mboxcl2', $smsg);
	my $bdy = delete($eml->{bdy}) // \(my $empty = '');
	_mboxcl_common($buf, $bdy, $eml->{crlf});
}

sub git_to_mail { # git->cat_async callback
	my ($bref, $oid, $type, $size, $arg) = @_;
	$type // return; # called by git->async_abort
	my ($write_cb, $smsg) = @$arg;
	if ($type eq 'missing' && $smsg->{-lms_rw}) {
		if ($bref = $smsg->{-lms_rw}->local_blob($oid, 1)) {
			$type = 'blob';
			$size = length($$bref);
		}
	}
	return warn("W: $oid is $type (!= blob)\n") if $type ne 'blob';
	return warn("E: $oid is empty\n") unless $size;
	die "BUG: expected=$smsg->{blob} got=$oid" if $smsg->{blob} ne $oid;
	$write_cb->($bref, $smsg);
}

sub reap_compress { # dwaitpid callback
	my ($lei, $pid) = @_;
	my $cmd = delete $lei->{"pid.$pid"};
	return if $? == 0;
	$lei->fail("@$cmd failed", $? >> 8);
}

sub _post_augment_mbox { # open a compressor process from top-level process
	my ($self, $lei) = @_;
	my $zsfx = $self->{zsfx} or return;
	my $cmd = PublicInbox::MboxReader::zsfx2cmd($zsfx, undef, $lei);
	my ($r, $w) = @{delete $lei->{zpipe}};
	my $rdr = { 0 => $r, 1 => $lei->{1}, 2 => $lei->{2}, pgid => 0 };
	my $pid = spawn($cmd, undef, $rdr);
	my $pp = gensym;
	my $dup = bless { "pid.$pid" => $cmd }, ref($lei);
	$dup->{$_} = $lei->{$_} for qw(2 sock);
	tie *$pp, 'PublicInbox::ProcessPipe', $pid, $w, \&reap_compress, $dup;
	$lei->{1} = $pp;
}

# --augment existing output destination, with deduplication
sub _augment { # MboxReader eml_cb
	my ($eml, $lei) = @_;
	# ignore return value, just populate the skv
	$lei->{dedupe}->is_dup($eml);
}

sub _mbox_augment_kw_maybe {
	my ($eml, $lei, $lse, $augment) = @_;
	my $kw = PublicInbox::MboxReader::mbox_keywords($eml);
	update_kw_maybe($lei, $lse, $eml, $kw);
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
	my $lse = $lei->{lse}; # may be undef
	my $set_recent = $dedupe->has_entries;
	sub { # for git_to_mail
		my ($buf, $smsg, $eml) = @_;
		$eml //= PublicInbox::Eml->new($buf);
		return if $dedupe->is_dup($eml, $smsg);
		$lse->xsmsg_vmd($smsg) if $lse;
		$smsg->{-recent} = 1 if $set_recent;
		$buf = $eml2mbox->($eml, $smsg);
		if ($atomic_append) {
			atomic_append($lei, $buf);
		} else {
			my $lk = $ovv->lock_for_scope;
			$lei->out($$buf);
		}
		++$lei->{-nr_write};
	}
}

sub update_kw_maybe ($$$$) {
	my ($lei, $lse, $eml, $kw) = @_;
	return unless $lse;
	my $c = $lse->kw_changed($eml, $kw, my $docids = []);
	my $vmd = { kw => $kw };
	if (scalar @$docids) { # already in lei/store
		$lei->{sto}->wq_do('set_eml_vmd', undef, $vmd, $docids) if $c;
	} elsif (my $xoids = $lei->{ale}->xoids_for($eml)) {
		# it's in an external, only set kw, here
		$lei->{sto}->wq_do('set_xvmd', $xoids, $eml, $vmd);
	} else { # never-before-seen, import the whole thing
		# XXX this is critical in protecting against accidental
		# data loss without --augment
		$lei->{sto}->wq_do('set_eml', $eml, $vmd);
	}
}

sub _md_update { # maildir_each_eml cb
	my ($f, $kw, $eml, $lei, $lse, $unlink) = @_;
	update_kw_maybe($lei, $lse, $eml, $kw);
	$unlink ? unlink($f) : _augment($eml, $lei);
}

# maildir_each_file callback, \&CORE::unlink doesn't work with it
sub _unlink { unlink($_[0]) }

sub _rand () {
	state $seq = 0;
	sprintf('%x,%x,%x,%x', rand(0xffffffff), time, $$, ++$seq);
}

sub kw2suffix ($;@) {
	my $kw = shift;
	join('', sort(map { $kw2char{$_} // () } @$kw, @_));
}

sub _buf2maildir ($$$$) {
	my ($dst, $buf, $smsg, $dir) = @_;
	my $kw = $smsg->{kw} // [];
	my $rand = ''; # chosen by die roll :P
	my ($tmp, $fh, $base, $ok);
	my $common = $smsg->{blob} // _rand;
	if (defined(my $pct = $smsg->{pct})) { $common .= "=$pct" }
	do {
		$tmp = $dst.'tmp/'.$rand.$common;
	} while (!($ok = sysopen($fh, $tmp, O_CREAT|O_EXCL|O_WRONLY)) &&
		$!{EEXIST} && ($rand = _rand.','));
	if ($ok && print $fh $$buf and close($fh)) {
		$dst .= $dir; # 'new/' or 'cur/'
		$rand = '';
		do {
			$base = $rand.$common.':2,'.kw2suffix($kw);
		} while (!($ok = rename_noreplace($tmp, $dst.$base)) &&
			$!{EEXIST} && ($rand = _rand.','));
		\$base;
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
	my $lse = $lei->{lse}; # may be undef
	my $lms = $self->{-lms_rw};
	my $out = $lms ? 'maildir:'.$lei->abs_path($dst) : undef;
	$lms->lms_write_prepare if $lms;

	# Favor cur/ and only write to new/ when augmenting.  This
	# saves MUAs from having to do a mass rename when the initial
	# search result set is huge.
	my $dir = $dedupe && $dedupe->has_entries ? 'new/' : 'cur/';
	sub { # for git_to_mail
		my ($bref, $smsg, $eml) = @_;
		$dst // return $lei->fail; # dst may be undef-ed in last run
		return if $dedupe && $dedupe->is_dup($eml //
						PublicInbox::Eml->new($$bref),
						$smsg);
		$lse->xsmsg_vmd($smsg) if $lse;
		my $n = _buf2maildir($dst, $bref // \($eml->as_string),
					$smsg, $dir);
		$lms->set_src($smsg->oidbin, $out, $n) if $lms;
		++$lei->{-nr_write};
	}
}

sub _imap_write_cb ($$) {
	my ($self, $lei) = @_;
	my $dedupe = $lei->{dedupe};
	$dedupe->prepare_dedupe if $dedupe;
	my $append = $lei->{net}->can('imap_append');
	my $uri = $self->{uri};
	my $mic = $lei->{net}->mic_get($uri);
	my $folder = $uri->mailbox;
	$uri->uidvalidity($mic->uidvalidity($folder));
	my $lse = $lei->{lse}; # may be undef
	my $lms = $self->{-lms_rw};
	$lms->lms_write_prepare if $lms;
	sub { # for git_to_mail
		my ($bref, $smsg, $eml) = @_;
		$mic // return $lei->fail; # mic may be undef-ed in last run
		return if $dedupe && $dedupe->is_dup($eml //
						PublicInbox::Eml->new($$bref),
						$smsg);
		$lse->xsmsg_vmd($smsg) if $lse;
		my $uid = eval { $append->($mic, $folder, $bref, $smsg, $eml) };
		if (my $err = $@) {
			undef $mic;
			die $err;
		}
		# imap_append returns UID if IMAP server has UIDPLUS extension
		($lms && $uid =~ /\A[0-9]+\z/) and
			$lms->set_src($smsg->oidbin, $$uri, $uid + 0);
		++$lei->{-nr_write};
	}
}

sub _text_write_cb ($$) {
	my ($self, $lei) = @_;
	my $dedupe = $lei->{dedupe};
	$dedupe->prepare_dedupe if $dedupe;
	my $lvt = $lei->{lvt};
	my $ovv = $lei->{ovv};
	$lei->{1} // die "no stdout ($ovv->{dst})"; # redirected earlier
	$lei->{1}->autoflush(1);
	binmode $lei->{1}, ':utf8';
	my $lse = $lei->{lse}; # may be undef
	sub { # for git_to_mail
		my ($bref, $smsg, $eml) = @_;
		$lse->xsmsg_vmd($smsg) if $lse;
		$eml //= PublicInbox::Eml->new($bref);
		return if $dedupe && $dedupe->is_dup($eml, $smsg);
		my $lk = $ovv->lock_for_scope;
		$lei->out(${$lvt->eml_to_text($smsg, $eml)}, "\n");
	}
}

sub _v2_write_cb ($$) {
	my ($self, $lei) = @_;
	my $dedupe = $lei->{dedupe};
	$dedupe->prepare_dedupe if $dedupe;
	sub { # for git_to_mail
		my ($bref, $smsg, $eml) = @_;
		$eml //= PublicInbox::Eml->new($bref);
		return if $dedupe && $dedupe->is_dup($eml, $smsg);
		$lei->{v2w}->wq_do('add', $eml); # V2Writable->add
		++$lei->{-nr_write};
	}
}

sub write_cb { # returns a callback for git_to_mail
	my ($self, $lei) = @_;
	# _mbox_write_cb, _maildir_write_cb, _imap_write_cb, _v2_write_cb
	my $m = "_$self->{base_type}_write_cb";
	$self->$m($lei);
}

sub new {
	my ($cls, $lei) = @_;
	my $fmt = $lei->{ovv}->{fmt};
	my $dst = $lei->{ovv}->{dst};
	my $self = bless {}, $cls;
	my @conflict;
	if ($fmt eq 'maildir') {
		require PublicInbox::MdirReader;
		$self->{base_type} = 'maildir';
		-e $dst && !-d _ and die
				"$dst exists and is not a directory\n";
		$lei->{ovv}->{dst} = $dst .= '/' if substr($dst, -1) ne '/';
		$lei->{opt}->{save} //= \1 if $lei->{cmd} eq 'q';
	} elsif (substr($fmt, 0, 4) eq 'mbox') {
		require PublicInbox::MboxReader;
		$self->can("eml2$fmt") or die "bad mbox format: $fmt\n";
		$self->{base_type} = 'mbox';
		if ($lei->{cmd} eq 'q' &&
				(($lei->path_to_fd($dst) // -1) < 0) &&
				(-f $dst || !-e _)) {
			$lei->{opt}->{save} //= \1;
		}
	} elsif ($fmt =~ /\Aimaps?\z/) {
		require PublicInbox::NetWriter;
		require PublicInbox::URIimap;
		# {net} may exist from "lei up" for auth
		my $net = $lei->{net} // PublicInbox::NetWriter->new;
		$net->{quiet} = $lei->{opt}->{quiet};
		my $uri = PublicInbox::URIimap->new($dst)->canonical;
		$net->add_url($$uri);
		my $err = $net->errors($lei);
		return $lei->fail($err) if $err;
		$uri->mailbox or return $lei->fail("No mailbox: $dst");
		$self->{uri} = $uri;
		$dst = $lei->{ovv}->{dst} = $$uri; # canonicalized
		$lei->{net} = $net;
		$self->{base_type} = 'imap';
		$lei->{opt}->{save} //= \1 if $lei->{cmd} eq 'q';
	} elsif ($fmt eq 'text' || $fmt eq 'reply') {
		require PublicInbox::LeiViewText;
		$lei->{lvt} = PublicInbox::LeiViewText->new($lei, $fmt);
		$self->{base_type} = 'text';
		$self->{-wq_nr_workers} = 1; # for pager
		@conflict = qw(mua save);
	} elsif ($fmt eq 'v2') {
		die "--dedupe=oid and v2 are incompatible\n" if
			($lei->{opt}->{dedupe}//'') eq 'oid';
		$self->{base_type} = 'v2';
		$self->{-wq_nr_workers} = 1; # v2 has shards
		$lei->{opt}->{save} = \1;
		$dst = $lei->{ovv}->{dst} = $lei->abs_path($dst);
		@conflict = qw(mua sort);
	} else {
		die "bad mail --format=$fmt\n";
	}
	if ($self->{base_type} =~ /\A(?:text|mbox)\z/) {
		(-d $dst || (-e _ && !-w _)) and die
			"$dst exists and is not a writable file\n";
	}
	my @err = map { defined($lei->{opt}->{$_}) ? "--$_" : () } @conflict;
	die "@err incompatible with $fmt\n" if @err;
	$self->{dst} = $dst;
	$lei->{dedupe} = $lei->{lss} // do {
		my $dd_cls = 'PublicInbox::'.
			($lei->{opt}->{save} ? 'LeiSavedSearch' : 'LeiDedupe');
		eval "require $dd_cls";
		die "$dd_cls: $@" if $@;
		my $dd = $dd_cls->new($lei);
		$lei->{lss} //= $dd if $dd && $dd->can('cfg_set');
		$dd;
	};
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
	# for utime, so no opendir
	open $self->{poke_dh}, '<', "${dst}cur" or die "open ${dst}cur: $!";
}

sub clobber_dst_prepare ($;$) {
	my ($lei, $f) = @_;
	if (my $lms = defined($f) ? $lei->lms : undef) {
		$lms->lms_write_prepare;
		$lms->forget_folders($f);
	}
	my $dedupe = $lei->{dedupe} or return;
	$dedupe->reset_dedupe if $dedupe->can('reset_dedupe');
}

sub _do_augment_maildir {
	my ($self, $lei) = @_;
	return if $lei->{cmd} eq 'up';
	my $dst = $lei->{ovv}->{dst};
	my $lse = $lei->{opt}->{'import-before'} ? $lei->{lse} : undef;
	my $mdr = PublicInbox::MdirReader->new;
	if ($lei->{opt}->{augment}) {
		my $dedupe = $lei->{dedupe};
		if ($dedupe && $dedupe->prepare_dedupe) {
			$mdr->{shard_info} = $self->{shard_info};
			$mdr->maildir_each_eml($dst, \&_md_update, $lei, $lse);
			$dedupe->pause_dedupe;
		}
	} elsif ($lse) {
		clobber_dst_prepare($lei, "maildir:$dst");
		$mdr->{shard_info} = $self->{shard_info};
		$mdr->maildir_each_eml($dst, \&_md_update, $lei, $lse, 1);
	} else {# clobber existing Maildir
		clobber_dst_prepare($lei, "maildir:$dst");
		$mdr->maildir_each_file($dst, \&_unlink);
	}
}

sub _imap_augment_or_delete { # PublicInbox::NetReader::imap_each cb
	my ($uri, $uid, $kw, $eml, $lei, $lse, $delete_mic) = @_;
	update_kw_maybe($lei, $lse, $eml, $kw);
	if ($delete_mic) {
		$lei->{net}->imap_delete_1($uri, $uid, $delete_mic);
	} else {
		_augment($eml, $lei);
	}
}

sub _do_augment_imap {
	my ($self, $lei) = @_;
	return if $lei->{cmd} eq 'up';
	my $net = $lei->{net};
	my $lse = $lei->{opt}->{'import-before'} ? $lei->{lse} : undef;
	if ($lei->{opt}->{augment}) {
		my $dedupe = $lei->{dedupe};
		if ($dedupe && $dedupe->prepare_dedupe) {
			$net->imap_each($self->{uri}, \&_imap_augment_or_delete,
					$lei, $lse);
			$dedupe->pause_dedupe;
		}
	} elsif ($lse) {
		my $delete_mic;
		clobber_dst_prepare($lei, "$self->{uri}");
		$net->imap_each($self->{uri}, \&_imap_augment_or_delete,
					$lei, $lse, \$delete_mic);
		$delete_mic->expunge if $delete_mic;
	} elsif (!$self->{-wq_worker_nr}) { # undef or 0
		# clobber existing IMAP folder
		clobber_dst_prepare($lei, "$self->{uri}");
		$net->imap_delete_all($self->{uri});
	}
}

sub _pre_augment_text {
	my ($self, $lei) = @_;
	my $dst = $lei->{ovv}->{dst};
	my $out;
	my $devfd = $lei->path_to_fd($dst) // die "bad $dst";
	if ($devfd >= 0) {
		$out = $lei->{$devfd};
	} else { # normal-looking path
		if (-p $dst) {
			open $out, '>', $dst or die "open($dst): $!";
		} elsif (-f _ || !-e _) {
			# text allows augment, HTML/Atom won't
			my $mode = $lei->{opt}->{augment} ? '>>' : '>';
			open $out, $mode, $dst or die "open($mode, $dst): $!";
		} else {
			die "$dst is not a file or FIFO\n";
		}
	}
	$lei->{ovv}->ovv_out_lk_init if !$lei->{ovv}->{lock_path};
	$lei->{1} = $out;
	undef;
}

sub _pre_augment_mbox {
	my ($self, $lei) = @_;
	my $dst = $lei->{ovv}->{dst};
	my $out;
	my $devfd = $lei->path_to_fd($dst) // die "bad $dst";
	if ($devfd >= 0) {
		$out = $lei->{$devfd};
	} else { # normal-looking path
		if (-p $dst) {
			open $out, '>', $dst or die "open($dst): $!";
		} elsif (-f _ || !-e _) {
			require PublicInbox::MboxLock;
			my $m = $lei->{opt}->{'lock'} //
					PublicInbox::MboxLock->defaults;
			$self->{mbl} = PublicInbox::MboxLock->acq($dst, 1, $m);
			$out = $self->{mbl}->{fh};
		} else {
			die "$dst is not a file or FIFO\n";
		}
		$lei->{old_1} = $lei->{1}; # keep for spawning MUA
	}
	# Perl does SEEK_END even with O_APPEND :<
	$self->{seekable} = seek($out, 0, SEEK_SET);
	if (!$self->{seekable} && !$!{ESPIPE} && !defined($devfd)) {
		die "seek($dst): $!\n";
	}
	if (!$self->{seekable}) {
		my $imp_before = $lei->{opt}->{'import-before'};
		die "--import-before specified but $dst is not seekable\n"
			if $imp_before && !ref($imp_before);
		die "--augment specified but $dst is not seekable\n" if
			$lei->{opt}->{augment};
		die "cannot --save with unseekable $dst\n" if
			$lei->{dedupe} && $lei->{dedupe}->can('reset_dedupe');
	}
	if ($self->{zsfx} = PublicInbox::MboxReader::zsfx($dst)) {
		pipe(my ($r, $w)) or die "pipe: $!";
		$lei->{zpipe} = [ $r, $w ];
		$lei->{ovv}->{lock_path} and
			die 'BUG: unexpected {ovv}->{lock_path}';
		$lei->{ovv}->ovv_out_lk_init;
	} elsif (!$self->{seekable} && !$lei->{ovv}->{lock_path}) {
		$lei->{ovv}->ovv_out_lk_init;
	}
	$lei->{1} = $out;
	undef;
}

sub _do_augment_mbox {
	my ($self, $lei) = @_;
	return unless $self->{seekable};
	my $opt = $lei->{opt};
	return if $lei->{cmd} eq 'up';
	my $out = $lei->{1};
	my ($fmt, $dst) = @{$lei->{ovv}}{qw(fmt dst)};
	return clobber_dst_prepare($lei) unless -s $out;
	unless ($opt->{augment} || $opt->{'import-before'}) {
		truncate($out, 0) or die "truncate($dst): $!";
		return;
	}
	my $rd;
	if (my $zsfx = $self->{zsfx}) {
		$rd = PublicInbox::MboxReader::zsfxcat($out, $zsfx, $lei);
	} else {
		open($rd, '+>>&', $out) or die "dup: $!";
	}
	my $dedupe;
	if ($opt->{augment}) {
		$dedupe = $lei->{dedupe};
		$dedupe->prepare_dedupe if $dedupe;
	} else {
		clobber_dst_prepare($lei);
	}
	if ($opt->{'import-before'}) { # the default
		my $lse = $lei->{lse};
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

sub v2w_done_wait { # dwaitpid callback
	my ($arg, $pid) = @_;
	my ($v2w, $lei) = @$arg;
	$lei->child_error($?, "error for $v2w->{ibx}->{inboxdir}") if $?;
}

sub _pre_augment_v2 {
	my ($self, $lei) = @_;
	my $dir = $self->{dst};
	require PublicInbox::InboxWritable;
	my ($ibx, @creat);
	if (-d $dir) {
		my $opt = { -min_inbox_version => 2 };
		require PublicInbox::Admin;
		my @ibx = PublicInbox::Admin::resolve_inboxes([ $dir ], $opt);
		$ibx = $ibx[0] or die "$dir is not a v2 inbox\n";
	} else {
		$creat[0] = {};
		$ibx = PublicInbox::Inbox->new({
			name => 'lei-result', # XXX configurable
			inboxdir => $dir,
			version => 2,
			address => [ 'lei@example.com' ],
		});
	}
	PublicInbox::InboxWritable->new($ibx, @creat);
	$ibx->init_inbox if @creat;
	my $v2w = $ibx->importer;
	$v2w->wq_workers_start("lei/v2w $dir", 1, $lei->oldset, {lei => $lei});
	$v2w->wq_wait_async(\&v2w_done_wait, $lei);
	$lei->{v2w} = $v2w;
	return if !$lei->{opt}->{shared};
	my $d = "$lei->{ale}->{git}->{git_dir}/objects";
	my $al = "$dir/git/0.git/objects/info/alternates";
	open my $fh, '+>>', $al or die "open($al): $!";
	seek($fh, 0, SEEK_SET) or die "seek($al): $!";
	grep(/\A\Q$d\E\n/, <$fh>) and return;
	print $fh "$d\n" or die "print($al): $!";
	close $fh or die "close($al): $!";
}

sub pre_augment { # fast (1 disk seek), runs in same process as post_augment
	my ($self, $lei) = @_;
	# _pre_augment_maildir, _pre_augment_mbox, _pre_augment_v2
	my $m = $self->can("_pre_augment_$self->{base_type}") or return;
	$m->($self, $lei);
}

sub do_augment { # slow, runs in wq worker
	my ($self, $lei) = @_;
	# _do_augment_maildir, _do_augment_mbox, or _do_augment_imap
	my $m = $self->can("_do_augment_$self->{base_type}") or return;
	$m->($self, $lei);
}

# fast (spawn compressor or mkdir), runs in same process as pre_augment
sub post_augment {
	my ($self, $lei, @args) = @_;
	$self->{-au_noted}++ and $lei->qerr("# writing to $self->{dst} ...");

	my $wait = $lei->{opt}->{'import-before'} ?
			$lei->{sto}->wq_do('checkpoint', 1) : 0;
	# _post_augment_mbox
	my $m = $self->can("_post_augment_$self->{base_type}") or return;
	$m->($self, $lei, @args);
}

# called by every single l2m worker process
sub do_post_auth {
	my ($self) = @_;
	my $lei = $self->{lei};
	# lei_xsearch can start as soon as all l2m workers get here
	$lei->{pkt_op_p}->pkt_do('incr_start_query') or
		die "incr_start_query: $!";
	my $aug;
	if (lock_free($self)) { # all workers do_augment
		my $mod = $self->{-wq_nr_workers};
		my $shard = $self->{-wq_worker_nr};
		if (my $net = $lei->{net}) {
			$net->{shard_info} = [ $mod, $shard ];
		} else { # Maildir
			$self->{shard_info} = [ $mod, $shard ];
		}
		$aug = 'incr_post_augment';
	} elsif ($self->{-wq_worker_nr} == 0) { # 1st worker do_augment
		$aug = 'do_post_augment';
	}
	if ($aug) {
		local $0 = 'do_augment';
		eval { do_augment($self, $lei) };
		$lei->fail($@) if $@;
		$lei->{pkt_op_p}->pkt_do($aug) or die "pkt_do($aug): $!";
	}
	# done augmenting, connect the compressor pipe for each worker
	if (my $zpipe = delete $lei->{zpipe}) {
		$lei->{1} = $zpipe->[1];
		close $zpipe->[0];
	}
	my $au_peers = delete $self->{au_peers};
	if ($au_peers) { # wait for peer l2m to finish augmenting:
		$au_peers->[1] = undef;
		sysread($au_peers->[0], my $barrier1, 1);
	}
	$self->{wcb} = $self->write_cb($lei);
	if ($au_peers) { # wait for peer l2m to set write_cb
		$au_peers->[3] = undef;
		sysread($au_peers->[2], my $barrier2, 1);
	}
}

sub ipc_atfork_child {
	my ($self) = @_;
	my $lei = $self->{lei};
	$lei->_lei_atfork_child;
	$lei->{auth}->do_auth_atfork($self) if $lei->{auth};
	$SIG{__WARN__} = PublicInbox::Eml::warn_ignore_cb();
	$self->SUPER::ipc_atfork_child;
}

sub lock_free {
	$_[0]->{base_type} =~ /\A(?:maildir|imap|jmap)\z/ ? 1 : 0;
}

# wakes up the MUA when complete so it can refresh messages list
sub poke_dst {
	my ($self) = @_;
	if ($self->{base_type} eq 'maildir') {
		my $t = time + 1;
		utime($t, $t, $self->{poke_dh}) or warn "futimes: $!";
	}
}

sub write_mail { # via ->wq_io_do
	my ($self, $smsg, $eml) = @_;
	return $self->{wcb}->(undef, $smsg, $eml) if $eml;
	$smsg->{-lms_rw} = $self->{-lms_rw};
	$self->{lei}->{ale}->git->cat_async($smsg->{blob}, \&git_to_mail,
				[$self->{wcb}, $smsg]);
}

sub wq_atexit_child {
	my ($self) = @_;
	local $PublicInbox::DS::in_loop = 0; # waitpid synchronously
	my $lei = $self->{lei};
	delete $self->{wcb};
	$lei->{ale}->git->async_wait_all;
	my $nr = delete($lei->{-nr_write}) or return;
	return if $lei->{early_mua} || !$lei->{-progress} || !$lei->{pkt_op_p};
	$lei->{pkt_op_p}->pkt_do('l2m_progress', $nr);
}

# runs on a 1s timer in lei-daemon
sub augment_inprogress {
	my ($err, $opt, $dst, $au_noted) = @_;
	eval {
		return if $$au_noted++ || !$err || !defined(fileno($err));
		print $err '# '.($opt->{'import-before'} ?
				"importing non-external contents of $dst" : (
				($opt->{dedupe} // 'content') ne 'none') ?
				"scanning old contents of $dst for dedupe" :
				"removing old contents of $dst")." ...\n";
	};
	warn "E: $@ ($dst)" if $@;
}

# called in top-level lei-daemon when LeiAuth is done
sub net_merge_all_done {
	my ($self, $lei) = @_;
	if ($PublicInbox::DS::in_loop &&
			$self->can("_do_augment_$self->{base_type}") &&
			!$lei->{opt}->{quiet}) {
		$self->{-au_noted} = 0;
		PublicInbox::DS::add_timer(1, \&augment_inprogress,
				$lei->{2}, $lei->{opt},
				$self->{dst}, \$self->{-au_noted});
	}
	$self->wq_broadcast('do_post_auth');
	$self->wq_close;
}

1;
