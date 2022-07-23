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

sub zflush {} # noop

sub requeue_once ($) {
	my ($self) = @_;
	# COMPRESS users all share the same DEFLATE context.
	# Flush it here to ensure clients don't see
	# each other's data
	$self->zflush;

	# no recursion, schedule another call ASAP,
	# but only after all pending writes are done.
	# autovivify wbuf:
	my $new_size = push(@{$self->{wbuf}}, \&long_step);

	# wbuf may be populated by $cb, no need to rearm if so:
	$self->requeue if $new_size == 1;
}

sub long_step {
	my ($self) = @_;
	# wbuf is unset or empty, here; {long} may add to it
	my ($fd, $cb, $t0, @args) = @{$self->{long_cb}};
	my $more = eval { $cb->($self, @args) };
	if ($@ || !$self->{sock}) { # something bad happened...
		delete $self->{long_cb};
		my $elapsed = now() - $t0;
		if ($@) {
			err($self,
			    "%s during long response[$fd] - %0.6f",
			    $@, $elapsed);
		}
		out($self, " deferred[$fd] aborted - %0.6f", $elapsed);
		$self->close;
	} elsif ($more) { # $self->{wbuf}:
		# control passed to ibx_async_cat if $more == \undef
		requeue_once($self) if !ref($more);
	} else { # all done!
		delete $self->{long_cb};
		my $elapsed = now() - $t0;
		my $fd = fileno($self->{sock});
		out($self, " deferred[$fd] done - %0.6f", $elapsed);
		my $wbuf = $self->{wbuf}; # do NOT autovivify
		$self->requeue unless $wbuf && @$wbuf;
	}
}

sub long_response ($$;@) {
	my ($self, $cb, @args) = @_; # cb returns true if more, false if done
	my $sock = $self->{sock} or return;
	# make sure we disable reading during a long response,
	# clients should not be sending us stuff and making us do more
	# work while we are stream a response to them
	$self->{long_cb} = [ fileno($sock), $cb, now(), @args ];
	long_step($self); # kick off!
	undef;
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
	my $sock = $self->{sock} or return;
	return \"-ERR TLS already enabled\r\n" if $sock->can('stop_SSL');
	my $opt = $self->{pop3d}->{accept_tls} or
		return \"-ERR can't start TLS negotiation\r\n";
	$self->write(\"+OK begin TLS negotiation now\r\n");
	$self->{sock} = IO::Socket::SSL->start_SSL($sock, %$opt);
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
	my $opt = { limit => PublicInbox::IMAP::UID_SLICE };
	my $m = $self->{ibx}->over(1)->do_get(<<'', $opt, $beg, $end);
SELECT num,ddd FROM over WHERE num >= ? AND num <= ?
ORDER BY num ASC

	[ map { ($_->{num}, $_->{bytes} + 0, $_->{blob}) } @$m ];
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
			$self->{pop3d}->{accept_tls} ? "\nSTLS\r" : '';
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

sub cmd_quit {
	my ($self) = @_;
	if (defined(my $txn_id = $self->{txn_id})) {
		my $user_id = $self->{user_id} // die 'BUG: no {user_id}';
		if (my $exp = delete $self->{expire}) {
			mark_dele($self, $_) for unpack('S*', $exp);
		}
		my $dbh = $self->{pop3d}->{-state_dbh};
		my $lk = $self->{pop3d}->lock_for_scope;
		my $sth;
		$dbh->begin_work;

		if (defined $self->{txn_max_uid}) {
			$sth = $dbh->prepare_cached(<<'');
UPDATE deletes SET uid_dele = ? WHERE txn_id = ? AND uid_dele < ?

			$sth->execute($self->{txn_max_uid}, $txn_id,
					$self->{txn_max_uid});
		}
		$sth = $dbh->prepare_cached(<<'');
UPDATE users SET last_seen = ? WHERE user_id = ?

		$sth->execute(time, $user_id);
		$dbh->commit;
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
