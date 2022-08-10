# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Each instance of this represents a POP3 client connected to
# public-inbox-{netd,pop3d}.  Much of this was taken from IMAP.pm and NNTP.pm
#
# POP3 is one mailbox per-user, so the "USER" command is like the
# format of -imapd and is mapped to $NEWSGROUP.$SLICE (large inboxes
# are sliced into 50K mailboxes in both POP3 and IMAP to avoid overloading
# clients)
#
# Unlike IMAP, the "$NEWSGROUP" mailbox (without $SLICE) is a rolling
# window of the latest messages.  We can do this for POP3 since the
# typical POP3 session is short-lived while long-lived IMAP sessions
# would cause slices to grow on the server side without bounds.
#
# Like IMAP, POP3 also has per-session message sequence numbers (MSN),
# which require mapping to UIDs.  The offset of an entry into our
# per-client cache is: (MSN-1)
#
# fields:
# - uuid - 16-byte (binary) UUID representation (before successful login)
# - cache - one-dimentional arrayref of (UID, bytesize, oidhex)
# - nr_dele - number of deleted messages
# - expire - string of packed unsigned short offsets
# - user_id - user-ID mapped to UUID (on successful login + lock)
# - txn_max_uid - for storing max deleted UID persistently
# - ibx - PublicInbox::Inbox object
# - slice - unsigned integer slice number (0..Inf), -1 => latest
# - salt - pre-auth for APOP
# - uid_dele - maximum deleted from previous session at login (NNTP ARTICLE)
# - uid_base - base UID for mailbox slice (0-based) (same as IMAP)
package PublicInbox::POP3;
use v5.12;
use parent qw(PublicInbox::DS);
use PublicInbox::GitAsyncCat;
use PublicInbox::DS qw(now);
use Errno qw(EAGAIN);
use Digest::MD5 qw(md5);
use PublicInbox::IMAP; # for UID slice stuff

use constant {
	LINE_MAX => 512, # XXX unsure
};

# XXX FIXME: duplicated stuff from NNTP.pm and IMAP.pm

sub err ($$;@) {
	my ($self, $fmt, @args) = @_;
	printf { $self->{pop3d}->{err} } $fmt."\n", @args;
}

sub out ($$;@) {
	my ($self, $fmt, @args) = @_;
	printf { $self->{pop3d}->{out} } $fmt."\n", @args;
}

sub do_greet {
	my ($self) = @_;
	my $s = $self->{salt} = sprintf('%x.%x', int(rand(0x7fffffff)), time);
	$self->write("+OK POP3 server ready <$s\@public-inbox>\r\n");
}

sub new {
	my ($cls, $sock, $pop3d) = @_;
	(bless { pop3d => $pop3d }, $cls)->greet($sock)
}

# POP user is $UUID1@$NEWSGROUP.$SLICE
sub cmd_user ($$) {
	my ($self, $mailbox) = @_;
	$self->{salt} // return \"-ERR already authed\r\n";
	$mailbox =~ s/\A([a-f0-9\-]+)\@//i or
		return \"-ERR no UUID@ in mailbox name\r\n";
	my $user = $1;
	$user =~ tr/-//d; # most have dashes, some (dbus-uuidgen) don't
	$user =~ m!\A[a-f0-9]{32}\z!i or return \"-ERR user has no UUID\r\n";
	my $slice;
	$mailbox =~ s/\.([0-9]+)\z// and $slice = $1 + 0;
	my $ibx = $self->{pop3d}->{pi_cfg}->lookup_newsgroup($mailbox) //
		return \"-ERR $mailbox does not exist\r\n";
	my $uidmax = $ibx->mm(1)->num_highwater // 0;
	if (defined $slice) {
		my $max = int($uidmax / PublicInbox::IMAP::UID_SLICE);
		my $tip = "$mailbox.$max";
		return \"-ERR $mailbox.$slice does not exist ($tip does)\r\n"
			if $slice > $max;
		$self->{uid_base} = $slice * PublicInbox::IMAP::UID_SLICE;
		$self->{slice} = $slice;
	} else { # latest 50K messages
		my $base = $uidmax - PublicInbox::IMAP::UID_SLICE;
		$self->{uid_base} = $base < 0 ? 0 : $base;
		$self->{slice} = -1;
	}
	$self->{ibx} = $ibx;
	$self->{uuid} = pack('H*', $user); # deleted by _login_ok
	$slice //= '(latest)';
	\"+OK $ibx->{newsgroup} slice=$slice selected\r\n";
}

sub _login_ok ($) {
	my ($self) = @_;
	if ($self->{pop3d}->lock_mailbox($self)) {
		$self->{uid_max} = $self->{ibx}->over(1)->max;
		\"+OK logged in\r\n";
	} else {
		\"-ERR [IN-USE] unable to lock maildrop\r\n";
	}
}

sub cmd_apop {
	my ($self, $mailbox, $hex) = @_;
	my $res = cmd_user($self, $mailbox); # sets {uuid}
	return $res if substr($$res, 0, 1) eq '-';
	my $s = delete($self->{salt}) // die 'BUG: salt missing';
	return _login_ok($self) if md5("<$s\@public-inbox>anonymous") eq
				pack('H*', $hex);
	$self->{salt} = $s;
	\"-ERR APOP password mismatch\r\n";
}

sub cmd_pass {
	my ($self, $pass) = @_;
	$self->{ibx} // return \"-ERR mailbox unspecified\r\n";
	my $s = delete($self->{salt}) // return \"-ERR already authed\r\n";
	return _login_ok($self) if $pass eq 'anonymous';
	$self->{salt} = $s;
	\"-ERR password is not `anonymous'\r\n";
}

sub cmd_stls {
	my ($self) = @_;
	($self->{sock} // return)->can('stop_SSL') and
		return \"-ERR TLS already enabled\r\n";
	$self->{pop3d}->{ssl_ctx_opt} or
		return \"-ERR can't start TLS negotiation\r\n";
	$self->write(\"+OK begin TLS negotiation now\r\n");
	PublicInbox::TLS::start($self->{sock}, $self->{pop3d});
	$self->requeue if PublicInbox::DS::accept_tls_step($self);
	undef;
}

sub need_txn ($) {
	exists($_[0]->{salt}) ? \"-ERR not in TRANSACTION\r\n" : undef;
}

sub _stat_cache ($) {
	my ($self) = @_;
	my ($beg, $end) = (($self->{uid_dele} // -1) + 1, $self->{uid_max});
	PublicInbox::IMAP::uid_clamp($self, \$beg, \$end);
	my (@cache, $m);
	my $sth = $self->{ibx}->over(1)->dbh->prepare_cached(<<'', undef, 1);
SELECT num,ddd FROM over WHERE num >= ? AND num <= ?
ORDER BY num ASC

	$sth->execute($beg, $end);
	do {
		$m = $sth->fetchall_arrayref({}, 1000);
		for my $x (@$m) {
			PublicInbox::Over::load_from_row($x);
			push(@cache, $x->{num}, $x->{bytes} + 0, $x->{blob});
			undef $x; # saves ~1.5M memory w/ 50k messages
		}
	} while (scalar(@$m) && ($beg = $cache[-3] + 1));
	\@cache;
}

sub cmd_stat {
	my ($self) = @_;
	my $err; $err = need_txn($self) and return $err;
	my $cache = $self->{cache} //= _stat_cache($self);
	my $tot = 0;
	for (my $i = 1; $i < scalar(@$cache); $i += 3) { $tot += $cache->[$i] }
	my $nr = @$cache / 3 - ($self->{nr_dele} // 0);
	"+OK $nr $tot\r\n";
}

# for LIST and UIDL
sub _list {
	my ($desc, $idx, $self, $msn) = @_;
	my $err; $err = need_txn($self) and return $err;
	my $cache = $self->{cache} //= _stat_cache($self);
	if (defined $msn) {
		my $base_off = ($msn - 1) * 3;
		my $val = $cache->[$base_off + $idx] //
				return \"-ERR no such message\r\n";
		"+OK $desc listing follows\r\n$msn $val\r\n.\r\n";
	} else { # always +OK, even if no messages
		my $res = "+OK $desc listing follows\r\n";
		my $msn = 0;
		for (my $i = 0; $i < scalar(@$cache); $i += 3) {
			++$msn;
			defined($cache->[$i]) and
				$res .= "$msn $cache->[$i + $idx]\r\n";
		}
		$res .= ".\r\n";
	}
}

sub cmd_list { _list('scan', 1, @_) }
sub cmd_uidl { _list('unique-id', 2, @_) }

sub mark_dele ($$) {
	my ($self, $off) = @_;
	my $base_off = $off * 3;
	my $cache = $self->{cache};
	my $uid = $cache->[$base_off] // return; # already deleted

	my $old = $self->{txn_max_uid} //= $uid;
	$self->{txn_max_uid} = $uid if $uid > $old;

	$cache->[$base_off] = undef; # clobber UID
	$cache->[$base_off + 1] = 0; # zero bytes (simplifies cmd_stat)
	$cache->[$base_off + 2] = undef; # clobber oidhex
	++$self->{nr_dele};
}

sub retr_cb { # called by git->cat_async via ibx_async_cat
	my ($bref, $oid, $type, $size, $args) = @_;
	my ($self, $off, $top_nr) = @$args;
	my $hex = $self->{cache}->[$off * 3 + 2] //
		die "BUG: no hex (oid=$oid)";
	if (!defined($oid)) {
		# it's possible to have TOCTOU if an admin runs
		# public-inbox-(edit|purge), just move onto the next message
		warn "E: $hex missing in $self->{ibx}->{inboxdir}\n";
		$self->write(\"-ERR no such message\r\n");
		return $self->requeue;
	} elsif ($hex ne $oid) {
		$self->close;
		die "BUG: $hex != $oid";
	}
	PublicInbox::IMAP::to_crlf_full($bref);
	if (defined $top_nr) {
		my ($hdr, $bdy) = split(/\r\n\r\n/, $$bref, 2);
		$bref = \$hdr;
		$hdr .= "\r\n\r\n";
		my @tmp = split(/^/m, $bdy);
		$hdr .= join('', splice(@tmp, 0, $top_nr));
	} elsif (exists $self->{expire}) {
		$self->{expire} .= pack('S', $off + 1);
	}
	$$bref =~ s/^\./../gms;
	$$bref .= substr($$bref, -2, 2) eq "\r\n" ? ".\r\n" : "\r\n.\r\n";
	$self->msg_more("+OK message follows\r\n");
	$self->write($bref);
	$self->requeue;
}

sub cmd_retr {
	my ($self, $msn, $top_nr) = @_;
	return \"-ERR lines must be a non-negative number\r\n" if
			(defined($top_nr) && $top_nr !~ /\A[0-9]+\z/);
	my $err; $err = need_txn($self) and return $err;
	my $cache = $self->{cache} //= _stat_cache($self);
	my $off = $msn - 1;
	my $hex = $cache->[$off * 3 + 2] // return \"-ERR no such message\r\n";
	${ibx_async_cat($self->{ibx}, $hex, \&retr_cb,
			[ $self, $off, $top_nr ])};
}

sub cmd_noop { $_[0]->write(\"+OK\r\n") }

sub cmd_rset {
	my ($self) = @_;
	my $err; $err = need_txn($self) and return $err;
	delete $self->{cache};
	delete $self->{txn_max_uid};
	\"+OK\r\n";
}

sub cmd_dele {
	my ($self, $msn) = @_;
	my $err; $err = need_txn($self) and return $err;
	$self->{cache} //= _stat_cache($self);
	$msn =~ /\A[1-9][0-9]*\z/ or return \"-ERR no such message\r\n";
	mark_dele($self, $msn - 1) ? \"+OK\r\n" : \"-ERR no such message\r\n";
}

# RFC 2449
sub cmd_capa {
	my ($self) = @_;
	my $STLS = !$self->{ibx} && !$self->{sock}->can('stop_SSL') &&
			$self->{pop3d}->{ssl_ctx_opt} ? "\nSTLS\r" : '';
	$self->{expire} = ''; # "EXPIRE 0" allows clients to avoid DELE commands
	<<EOM;
+OK Capability list follows\r
TOP\r
USER\r
PIPELINING\r
UIDL\r
EXPIRE 0\r
RESP-CODES\r$STLS
.\r
EOM
}

sub close {
	my ($self) = @_;
	$self->{pop3d}->unlock_mailbox($self);
	$self->SUPER::close;
}

# must be called inside a state_dbh transaction with flock held
sub __cleanup_state {
	my ($self, $txn_id) = @_;
	my $user_id = $self->{user_id} // die 'BUG: no {user_id}';
	$self->{pop3d}->{-state_dbh}->prepare_cached(<<'')->execute($txn_id);
DELETE FROM deletes WHERE txn_id = ? AND uid_dele = -1

	my $sth = $self->{pop3d}->{-state_dbh}->prepare_cached(<<'');
SELECT COUNT(*) FROM deletes WHERE user_id = ?

	$sth->execute($user_id);
	my $nr = $sth->fetchrow_array;
	if ($nr == 0) {
		$sth = $self->{pop3d}->{-state_dbh}->prepare_cached(<<'');
DELETE FROM users WHERE user_id = ?

		$sth->execute($user_id);
	}
	$nr;
}

sub cmd_quit {
	my ($self) = @_;
	if (defined(my $txn_id = $self->{txn_id})) {
		my $user_id = $self->{user_id} // die 'BUG: no {user_id}';
		if (my $exp = delete $self->{expire}) {
			mark_dele($self, $_) for unpack('S*', $exp);
		}
		my $keep = 1;
		my $dbh = $self->{pop3d}->{-state_dbh};
		my $lk = $self->{pop3d}->lock_for_scope;
		$dbh->begin_work;

		if (defined(my $max = $self->{txn_max_uid})) {
			$dbh->prepare_cached(<<'')->execute($max, $txn_id, $max)
UPDATE deletes SET uid_dele = ? WHERE txn_id = ? AND uid_dele < ?

		} else {
			$keep = $self->__cleanup_state($txn_id);
		}
		$dbh->prepare_cached(<<'')->execute(time, $user_id) if $keep;
UPDATE users SET last_seen = ? WHERE user_id = ?

		$dbh->commit;
		# we MUST do txn_id F_UNLCK here inside ->lock_for_scope:
		$self->{did_quit} = 1;
		$self->{pop3d}->unlock_mailbox($self);
	}
	$self->write(\"+OK public-inbox POP3 server signing off\r\n");
	$self->close;
	undef;
}

# returns 1 if we can continue, 0 if not due to buffered writes or disconnect
sub process_line ($$) {
	my ($self, $l) = @_;
	my ($req, @args) = split(/[ \t]+/, $l);
	return 1 unless defined($req); # skip blank line
	$req = $self->can('cmd_'.lc($req));
	my $res = $req ? eval { $req->($self, @args) } :
		\"-ERR command not recognized\r\n";
	my $err = $@;
	if ($err && $self->{sock}) {
		chomp($l);
		err($self, 'error from: %s (%s)', $l, $err);
		$res = \"-ERR program fault - command not performed\r\n";
	}
	defined($res) ? $self->write($res) : 0;
}

# callback used by PublicInbox::DS for any (e)poll (in/out/hup/err)
sub event_step {
	my ($self) = @_;
	local $SIG{__WARN__} = $self->{pop3d}->{warn_cb};
	return unless $self->flush_write && $self->{sock} && !$self->{long_cb};

	# only read more requests if we've drained the write buffer,
	# otherwise we can be buffering infinitely w/o backpressure
	my $rbuf = $self->{rbuf} // \(my $x = '');
	my $line = index($$rbuf, "\n");
	while ($line < 0) {
		return $self->close if length($$rbuf) >= LINE_MAX;
		$self->do_read($rbuf, LINE_MAX, length($$rbuf)) or return;
		$line = index($$rbuf, "\n");
	}
	$line = substr($$rbuf, 0, $line + 1, '');
	$line =~ s/\r?\n\z//s;
	return $self->close if $line =~ /[[:cntrl:]]/s;
	my $t0 = now();
	my $fd = fileno($self->{sock}); # may become invalid after process_line
	my $r = eval { process_line($self, $line) };
	my $pending = $self->{wbuf} ? ' pending' : '';
	out($self, "[$fd] %s - %0.6f$pending - $r", $line, now() - $t0);
	return $self->close if $r < 0;
	$self->rbuf_idle($rbuf);

	# maybe there's more pipelined data, or we'll have
	# to register it for socket-readiness notifications
	$self->requeue unless $pending;
}

no warnings 'once';
*cmd_top = \&cmd_retr;

1;
