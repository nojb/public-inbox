# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Each instance of this represents an IMAP client connected to
# public-inbox-imapd.  Much of this was taken from NNTP, but
# further refined while experimenting on future ideas to handle
# slow storage.
#
# data notes:
#
# * NNTP article numbers are UIDs, mm->created_at is UIDVALIDITY
#
# * public-inboxes are sliced into mailboxes of 50K messages
#   to not overload MUAs: $NEWSGROUP_NAME.$SLICE_INDEX
#   Slices are similar in concept to v2 "epochs".  Epochs
#   are for the limitations of git clients, while slices are
#   for the limitations of IMAP clients.
#
# * We also take advantage of slices being only 50K to store
#   "UID offset" to message sequence number (MSN) mapping
#   as a 50K uint16_t array (via pack("S*", ...)).  "UID offset"
#   is the offset from {uid_base} which determines the start of
#   the mailbox slice.
#
# fields:
# imapd: PublicInbox::IMAPD ref
# ibx: PublicInbox::Inbox ref
# long_cb: long_response private data
# uid_base: base UID for mailbox slice (0-based)
# -login_tag: IMAP TAG for LOGIN
# -idle_tag: IMAP response tag for IDLE
# uo2m: UID-to-MSN mapping
package PublicInbox::IMAP;
use strict;
use parent qw(PublicInbox::DS);
use PublicInbox::Eml;
use PublicInbox::EmlContentFoo qw(parse_content_disposition);
use PublicInbox::DS qw(now);
use PublicInbox::GitAsyncCat;
use Text::ParseWords qw(parse_line);
use Errno qw(EAGAIN);
use PublicInbox::IMAPsearchqp;

my $Address;
for my $mod (qw(Email::Address::XS Mail::Address)) {
	eval "require $mod" or next;
	$Address = $mod and last;
}
die "neither Email::Address::XS nor Mail::Address loaded: $@" if !$Address;

sub LINE_MAX () { 8000 } # RFC 2683 3.2.1.5

# Changing UID_SLICE will cause grief for clients which cache.
# This also needs to be <64K: we pack it into a uint16_t
# for long_response UID (offset) => MSN mappings
sub UID_SLICE () { 50_000 }

# these values area also used for sorting
sub NEED_SMSG () { 1 }
sub NEED_BLOB () { NEED_SMSG|2 }
sub CRLF_BREF () { 4 }
sub EML_HDR () { 8 }
sub CRLF_HDR () { 16 }
sub EML_BDY () { 32 }
sub CRLF_BDY () { 64 }
my $OP_EML_NEW = [ EML_HDR - 1, \&op_eml_new ];
my $OP_CRLF_BREF = [ CRLF_BREF, \&op_crlf_bref ];
my $OP_CRLF_HDR = [ CRLF_HDR, \&op_crlf_hdr ];
my $OP_CRLF_BDY = [ CRLF_BDY, \&op_crlf_bdy ];

my %FETCH_NEED = (
	'BODY[HEADER]' => [ NEED_BLOB|EML_HDR|CRLF_HDR, \&emit_rfc822_header ],
	'BODY[TEXT]' => [ NEED_BLOB|EML_BDY|CRLF_BDY, \&emit_rfc822_text ],
	'BODY[]' => [ NEED_BLOB|CRLF_BREF, \&emit_rfc822 ],
	'RFC822.HEADER' => [ NEED_BLOB|EML_HDR|CRLF_HDR, \&emit_rfc822_header ],
	'RFC822.TEXT' => [ NEED_BLOB|EML_BDY|CRLF_BDY, \&emit_rfc822_text ],
	'RFC822.SIZE' => [ NEED_SMSG, \&emit_rfc822_size ],
	RFC822 => [ NEED_BLOB|CRLF_BREF, \&emit_rfc822 ],
	BODY => [ NEED_BLOB|EML_HDR|EML_BDY, \&emit_body ],
	BODYSTRUCTURE => [ NEED_BLOB|EML_HDR|EML_BDY, \&emit_bodystructure ],
	ENVELOPE => [ NEED_BLOB|EML_HDR, \&emit_envelope ],
	FLAGS => [ 0, \&emit_flags ],
	INTERNALDATE => [ NEED_SMSG, \&emit_internaldate ],
);
my %FETCH_ATT = map { $_ => [ $_ ] } keys %FETCH_NEED;

# aliases (RFC 3501 section 6.4.5)
$FETCH_ATT{FAST} = [ qw(FLAGS INTERNALDATE RFC822.SIZE) ];
$FETCH_ATT{ALL} = [ @{$FETCH_ATT{FAST}}, 'ENVELOPE' ];
$FETCH_ATT{FULL} = [ @{$FETCH_ATT{ALL}}, 'BODY' ];

for my $att (keys %FETCH_ATT) {
	my %h = map { $_ => $FETCH_NEED{$_} } @{$FETCH_ATT{$att}};
	$FETCH_ATT{$att} = \%h;
}
undef %FETCH_NEED;

my $valid_range = '[0-9]+|[0-9]+:[0-9]+|[0-9]+:\*';
$valid_range = qr/\A(?:$valid_range)(?:,(?:$valid_range))*\z/;

sub do_greet {
	my ($self) = @_;
	my $capa = capa($self);
	$self->write(\"* OK [$capa] public-inbox-imapd ready\r\n");
}

sub new {
	my (undef, $sock, $imapd) = @_;
	(bless { imapd => $imapd }, 'PublicInbox::IMAP_preauth')->greet($sock)
}

sub logged_in { 1 }

sub capa ($) {
	my ($self) = @_;

	# dovecot advertises IDLE pre-login; perhaps because some clients
	# depend on it, so we'll do the same
	my $capa = 'CAPABILITY IMAP4rev1 IDLE';
	if ($self->logged_in) {
		$capa .= ' COMPRESS=DEFLATE';
	} else {
		if (!($self->{sock} // $self)->can('accept_SSL') &&
			$self->{imapd}->{accept_tls}) {
			$capa .= ' STARTTLS';
		}
		$capa .= ' AUTH=ANONYMOUS';
	}
}

sub login_success ($$) {
	my ($self, $tag) = @_;
	bless $self, 'PublicInbox::IMAP';
	my $capa = capa($self);
	"$tag OK [$capa] Logged in\r\n";
}

sub auth_challenge_ok ($) {
	my ($self) = @_;
	my $tag = delete($self->{-login_tag}) or return;
	login_success($self, $tag);
}

sub cmd_login ($$$$) {
	my ($self, $tag) = @_; # ignore ($user, $password) = ($_[2], $_[3])
	login_success($self, $tag);
}

sub cmd_close ($$) {
	my ($self, $tag) = @_;
	delete @$self{qw(uid_base uo2m)};
	delete $self->{ibx} ? "$tag OK Close done\r\n"
				: "$tag BAD No mailbox\r\n";
}

sub cmd_logout ($$) {
	my ($self, $tag) = @_;
	delete $self->{-idle_tag};
	$self->write(\"* BYE logging out\r\n$tag OK Logout done\r\n");
	$self->shutdn; # PublicInbox::DS::shutdn
	undef;
}

sub cmd_authenticate ($$$) {
	my ($self, $tag) = @_; # $method = $_[2], should be "ANONYMOUS"
	$self->{-login_tag} = $tag;
	"+\r\n"; # challenge
}

sub cmd_capability ($$) {
	my ($self, $tag) = @_;
	'* '.capa($self)."\r\n$tag OK Capability done\r\n";
}

# uo2m: UID Offset to MSN, this is an arrayref by default,
# but uo2m_hibernate can compact and deduplicate it
sub uo2m_ary_new ($;$) {
	my ($self, $exists) = @_;
	my $ub = $self->{uid_base};
	my $uids = $self->{ibx}->over(1)->uid_range($ub + 1, $ub + UID_SLICE);

	# convert UIDs to offsets from {base}
	my @tmp; # [$UID_OFFSET] => $MSN
	my $msn = 0;
	++$ub;
	$tmp[$_ - $ub] = ++$msn for @$uids;
	$$exists = $msn if $exists;
	\@tmp;
}

# changes UID-offset-to-MSN mapping into a deduplicated scalar:
# uint16_t uo2m[UID_SLICE].
# May be swapped out for idle clients if THP is disabled.
sub uo2m_hibernate ($) {
	my ($self) = @_;
	ref(my $uo2m = $self->{uo2m}) or return;
	my %dedupe = ( uo2m_pack($uo2m) => undef );
	$self->{uo2m} = (keys(%dedupe))[0];
	undef;
}

sub uo2m_last_uid ($) {
	my ($self) = @_;
	defined(my $uo2m = $self->{uo2m}) or die 'BUG: uo2m_last_uid w/o {uo2m}';
	(ref($uo2m) ? @$uo2m : (length($uo2m) >> 1)) + $self->{uid_base};
}

sub uo2m_pack ($) {
	# $_[0] is an arrayref of MSNs, it may have undef gaps if there
	# are gaps in the corresponding UIDs: [ msn1, msn2, undef, msn3 ]
	no warnings 'uninitialized';
	pack('S*', @{$_[0]});
}

# extend {uo2m} to account for new messages which arrived since
# {uo2m} was created.
sub uo2m_extend ($$;$) {
	my ($self, $new_uid_max) = @_;
	defined(my $uo2m = $self->{uo2m}) or
		return($self->{uo2m} = uo2m_ary_new($self));
	my $beg = uo2m_last_uid($self); # last UID we've learned
	return $uo2m if $beg >= $new_uid_max; # fast path

	# need to extend the current range:
	my $base = $self->{uid_base};
	++$beg;
	my $uids = $self->{ibx}->over(1)->uid_range($beg, $base + UID_SLICE);
	return $uo2m if !scalar(@$uids);
	my @tmp; # [$UID_OFFSET] => $MSN
	my $write_method = $_[2] // 'msg_more';
	if (ref($uo2m)) {
		my $msn = $uo2m->[-1];
		$tmp[$_ - $beg] = ++$msn for @$uids;
		$self->$write_method("* $msn EXISTS\r\n");
		push @$uo2m, @tmp;
		$uo2m;
	} else {
		my $msn = unpack('S', substr($uo2m, -2, 2));
		$tmp[$_ - $beg] = ++$msn for @$uids;
		$self->$write_method("* $msn EXISTS\r\n");
		$uo2m .= uo2m_pack(\@tmp);
		my %dedupe = ($uo2m => undef);
		$self->{uo2m} = (keys %dedupe)[0];
	}
}

sub cmd_noop ($$) {
	my ($self, $tag) = @_;
	defined($self->{uid_base}) and
		uo2m_extend($self, $self->{uid_base} + UID_SLICE);
	\"$tag OK Noop done\r\n";
}

# the flexible version which works on scalars and array refs.
# Must call uo2m_extend before this
sub uid2msn ($$) {
	my ($self, $uid) = @_;
	my $uo2m = $self->{uo2m};
	my $off = $uid - $self->{uid_base} - 1;
	ref($uo2m) ? $uo2m->[$off] : unpack('S', substr($uo2m, $off << 1, 2));
}

# returns an arrayref of UIDs, so MSNs can be translated to UIDs via:
# $msn2uid->[$MSN-1] => $UID.  The result of this is always ephemeral
# and does not live beyond the event loop.
sub msn2uid ($) {
	my ($self) = @_;
	my $base = $self->{uid_base};
	my $uo2m = uo2m_extend($self, $base + UID_SLICE);
	$uo2m = [ unpack('S*', $uo2m) ] if !ref($uo2m);

	my $uo = 0;
	my @msn2uid;
	for my $msn (@$uo2m) {
		++$uo;
		$msn2uid[$msn - 1] = $uo + $base if $msn;
	}
	\@msn2uid;
}

# converts a set of message sequence numbers in requests to UIDs:
sub msn_to_uid_range ($$) {
	my $msn2uid = $_[0];
	$_[1] =~ s!([0-9]+)!$msn2uid->[$1 - 1] // ($msn2uid->[-1] // 0 + 1)!sge;
}

# called by PublicInbox::InboxIdle
sub on_inbox_unlock {
	my ($self, $ibx) = @_;
	my $uid_end = $self->{uid_base} + UID_SLICE;
	uo2m_extend($self, $uid_end, 'write');
	my $new = uo2m_last_uid($self);
	if ($new == $uid_end) { # max exceeded $uid_end
		# continue idling w/o inotify
		my $sock = $self->{sock} or return;
		$ibx->unsubscribe_unlock(fileno($sock));
	}
}

# called every minute or so by PublicInbox::DS::later
my $IDLERS; # fileno($obj->{sock}) => PublicInbox::IMAP
sub idle_tick_all {
	my $old = $IDLERS;
	$IDLERS = undef;
	for my $i (values %$old) {
		next if ($i->{wbuf} || !exists($i->{-idle_tag}));
		$IDLERS->{fileno($i->{sock})} = $i;
		$i->write(\"* OK Still here\r\n");
	}
	$IDLERS and
		PublicInbox::DS::add_uniq_timer('idle', 60, \&idle_tick_all);
}

sub cmd_idle ($$) {
	my ($self, $tag) = @_;
	# IDLE seems allowed by dovecot w/o a mailbox selected *shrug*
	my $ibx = $self->{ibx} or return "$tag BAD no mailbox selected\r\n";
	my $uid_end = $self->{uid_base} + UID_SLICE;
	uo2m_extend($self, $uid_end);
	my $sock = $self->{sock} or return;
	my $fd = fileno($sock);
	$self->{-idle_tag} = $tag;
	# only do inotify on most recent slice
	if ($ibx->over(1)->max < $uid_end) {
		$ibx->subscribe_unlock($fd, $self);
		$self->{imapd}->idler_start;
	}
	PublicInbox::DS::add_uniq_timer('idle', 60, \&idle_tick_all);
	$IDLERS->{$fd} = $self;
	\"+ idling\r\n"
}

sub stop_idle ($$) {
	my ($self, $ibx) = @_;
	my $sock = $self->{sock} or return;
	my $fd = fileno($sock);
	delete $IDLERS->{$fd};
	$ibx->unsubscribe_unlock($fd);
}

sub idle_done ($$) {
	my ($self, $tag) = @_; # $tag is "DONE" (case-insensitive)
	defined(my $idle_tag = delete $self->{-idle_tag}) or
		return "$tag BAD not idle\r\n";
	my $ibx = $self->{ibx} or do {
		warn "BUG: idle_tag set w/o inbox";
		return "$tag BAD internal bug\r\n";
	};
	stop_idle($self, $ibx);
	"$idle_tag OK Idle done\r\n";
}

sub ensure_slices_exist ($$$) {
	my ($imapd, $ibx, $max) = @_;
	defined(my $mb_top = $ibx->{newsgroup}) or return;
	my $mailboxes = $imapd->{mailboxes};
	my @created;
	for (my $i = int($max/UID_SLICE); $i >= 0; --$i) {
		my $sub_mailbox = "$mb_top.$i";
		last if exists $mailboxes->{$sub_mailbox};
		$mailboxes->{$sub_mailbox} = $ibx;
		$sub_mailbox =~ s/\Ainbox\./INBOX./i; # more familiar to users
		push @created, $sub_mailbox;
	}
	return unless @created;
	my $l = $imapd->{mailboxlist} or return;
	push @$l, map { qq[* LIST (\\HasNoChildren) "." $_\r\n] } @created;
}

sub inbox_lookup ($$;$) {
	my ($self, $mailbox, $examine) = @_;
	my ($ibx, $exists, $uidmax, $uid_base) = (undef, 0, 0, 0);
	$mailbox = lc $mailbox;
	$ibx = $self->{imapd}->{mailboxes}->{$mailbox} or return;
	my $over = $ibx->over(1);
	if ($over != $ibx) { # not a dummy
		$mailbox =~ /\.([0-9]+)\z/ or
				die "BUG: unexpected dummy mailbox: $mailbox\n";
		$uid_base = $1 * UID_SLICE;

		$uidmax = $ibx->mm->num_highwater // 0;
		if ($examine) {
			$self->{uid_base} = $uid_base;
			$self->{ibx} = $ibx;
			$self->{uo2m} = uo2m_ary_new($self, \$exists);
		} else {
			my $uid_end = $uid_base + UID_SLICE;
			$exists = $over->imap_exists($uid_base, $uid_end);
		}
		ensure_slices_exist($self->{imapd}, $ibx, $over->max);
	} else {
		if ($examine) {
			$self->{uid_base} = $uid_base;
			$self->{ibx} = $ibx;
			delete $self->{uo2m};
		}
		# if "INBOX.foo.bar" is selected and "INBOX.foo.bar.0",
		# check for new UID ranges (e.g. "INBOX.foo.bar.1")
		if (my $z = $self->{imapd}->{mailboxes}->{"$mailbox.0"}) {
			ensure_slices_exist($self->{imapd}, $z,
						$z->over(1)->max);
		}
	}
	($ibx, $exists, $uidmax + 1, $uid_base);
}

sub cmd_examine ($$$) {
	my ($self, $tag, $mailbox) = @_;
	# XXX: do we need this? RFC 5162/7162
	my $ret = $self->{ibx} ? "* OK [CLOSED] previous closed\r\n" : '';
	my ($ibx, $exists, $uidnext, $base) = inbox_lookup($self, $mailbox, 1);
	return "$tag NO Mailbox doesn't exist: $mailbox\r\n" if !$ibx;
	$ret .= <<EOF;
* $exists EXISTS\r
* $exists RECENT\r
* FLAGS (\\Seen)\r
* OK [PERMANENTFLAGS ()] Read-only mailbox\r
* OK [UNSEEN $exists]\r
* OK [UIDNEXT $uidnext]\r
* OK [UIDVALIDITY $ibx->{uidvalidity}]\r
$tag OK [READ-ONLY] EXAMINE/SELECT done\r
EOF
}

sub _esc ($) {
	my ($v) = @_;
	if (!defined($v)) {
		'NIL';
	} elsif ($v =~ /[{"\r\n%*\\\[]/) { # literal string
		'{' . length($v) . "}\r\n" . $v;
	} else { # quoted string
		qq{"$v"}
	}
}

sub addr_envelope ($$;$) {
	my ($eml, $x, $y) = @_;
	my $v = $eml->header_raw($x) //
		($y ? $eml->header_raw($y) : undef) // return 'NIL';

	my @x = $Address->parse($v) or return 'NIL';
	'(' . join('',
		map { '(' . join(' ',
				_esc($_->name), 'NIL',
				_esc($_->user), _esc($_->host)
			) . ')'
		} @x) .
	')';
}

sub eml_envelope ($) {
	my ($eml) = @_;
	'(' . join(' ',
		_esc($eml->header_raw('Date')),
		_esc($eml->header_raw('Subject')),
		addr_envelope($eml, 'From'),
		addr_envelope($eml, 'Sender', 'From'),
		addr_envelope($eml, 'Reply-To', 'From'),
		addr_envelope($eml, 'To'),
		addr_envelope($eml, 'Cc'),
		addr_envelope($eml, 'Bcc'),
		_esc($eml->header_raw('In-Reply-To')),
		_esc($eml->header_raw('Message-ID')),
	) . ')';
}

sub _esc_hash ($) {
	my ($hash) = @_;
	if ($hash && scalar keys %$hash) {
		$hash = [ %$hash ]; # flatten hash into 1-dimensional array
		'(' . join(' ', map { _esc($_) } @$hash) . ')';
	} else {
		'NIL';
	}
}

sub body_disposition ($) {
	my ($eml) = @_;
	my $cd = $eml->header_raw('Content-Disposition') or return 'NIL';
	$cd = parse_content_disposition($cd);
	my $buf = '('._esc($cd->{type});
	$buf .= ' ' . _esc_hash($cd->{attributes});
	$buf .= ')';
}

sub body_leaf ($$;$) {
	my ($eml, $structure, $hold) = @_;
	my $buf = '';
	$eml->{is_submsg} and # parent was a message/(rfc822|news|global)
		$buf .= eml_envelope($eml). ' ';
	my $ct = $eml->ct;
	$buf .= '('._esc($ct->{type}).' ';
	$buf .= _esc($ct->{subtype});
	$buf .= ' ' . _esc_hash($ct->{attributes});
	$buf .= ' ' . _esc($eml->header_raw('Content-ID'));
	$buf .= ' ' . _esc($eml->header_raw('Content-Description'));
	my $cte = $eml->header_raw('Content-Transfer-Encoding') // '7bit';
	$buf .= ' ' . _esc($cte);
	$buf .= ' ' . $eml->{imap_body_len};
	$buf .= ' '.($eml->body_raw =~ tr/\n/\n/) if lc($ct->{type}) eq 'text';

	# for message/(rfc822|global|news), $hold[0] should have envelope
	$buf .= ' ' . (@$hold ? join('', @$hold) : 'NIL') if $hold;

	if ($structure) {
		$buf .= ' '._esc($eml->header_raw('Content-MD5'));
		$buf .= ' '. body_disposition($eml);
		$buf .= ' '._esc($eml->header_raw('Content-Language'));
		$buf .= ' '._esc($eml->header_raw('Content-Location'));
	}
	$buf .= ')';
}

sub body_parent ($$$) {
	my ($eml, $structure, $hold) = @_;
	my $ct = $eml->ct;
	my $type = lc($ct->{type});
	if ($type eq 'multipart') {
		my $buf = '(';
		$buf .= @$hold ? join('', @$hold) : 'NIL';
		$buf .= ' '._esc($ct->{subtype});
		if ($structure) {
			$buf .= ' '._esc_hash($ct->{attributes});
			$buf .= ' '.body_disposition($eml);
			$buf .= ' '._esc($eml->header_raw('Content-Language'));
			$buf .= ' '._esc($eml->header_raw('Content-Location'));
		}
		$buf .= ')';
		@$hold = ($buf);
	} else { # message/(rfc822|global|news)
		@$hold = (body_leaf($eml, $structure, $hold));
	}
}

# this is gross, but we need to process the parent part AFTER
# the child parts are done
sub bodystructure_prep {
	my ($p, $q) = @_;
	my ($eml, $depth) = @$p; # ignore idx
	# set length here, as $eml->{bdy} gets deleted for message/rfc822
	$eml->{imap_body_len} = length($eml->body_raw);
	push @$q, $eml, $depth;
}

# for FETCH BODY and FETCH BODYSTRUCTURE
sub fetch_body ($;$) {
	my ($eml, $structure) = @_;
	my @q;
	$eml->each_part(\&bodystructure_prep, \@q, 0, 1);
	my $cur_depth = 0;
	my @hold;
	do {
		my ($part, $depth) = splice(@q, -2);
		my $is_mp_parent = $depth == ($cur_depth - 1);
		$cur_depth = $depth;

		if ($is_mp_parent) {
			body_parent($part, $structure, \@hold);
		} else {
			unshift @hold, body_leaf($part, $structure);
		}
	} while (@q);
	join('', @hold);
}

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

sub fetch_run_ops {
	my ($self, $smsg, $bref, $ops, $partial) = @_;
	my $uid = $smsg->{num};
	$self->msg_more('* '.uid2msn($self, $uid)." FETCH (UID $uid");
	my ($eml, $k);
	for (my $i = 0; $i < @$ops;) {
		$k = $ops->[$i++];
		$ops->[$i++]->($self, $k, $smsg, $bref, $eml);
	}
	partial_emit($self, $partial, $eml) if $partial;
	$self->msg_more(")\r\n");
}

sub fetch_blob_cb { # called by git->cat_async via ibx_async_cat
	my ($bref, $oid, $type, $size, $fetch_arg) = @_;
	my ($self, undef, $msgs, $range_info, $ops, $partial) = @$fetch_arg;
	my $ibx = $self->{ibx} or return $self->close; # client disconnected
	my $smsg = shift @$msgs or die 'BUG: no smsg';
	if (!defined($oid)) {
		# it's possible to have TOCTOU if an admin runs
		# public-inbox-(edit|purge), just move onto the next message
		warn "E: $smsg->{blob} missing in $ibx->{inboxdir}\n";
		return requeue_once($self);
	} else {
		$smsg->{blob} eq $oid or die "BUG: $smsg->{blob} != $oid";
	}
	my $pre;
	if (!$self->{wbuf} && (my $nxt = $msgs->[0])) {
		$pre = ibx_async_prefetch($ibx, $nxt->{blob},
					\&fetch_blob_cb, $fetch_arg);
	}
	fetch_run_ops($self, $smsg, $bref, $ops, $partial);
	$pre ? $self->zflush : requeue_once($self);
}

sub emit_rfc822 {
	my ($self, $k, undef, $bref) = @_;
	$self->msg_more(" $k {" . length($$bref)."}\r\n");
	$self->msg_more($$bref);
}

# Mail::IMAPClient::message_string cares about this by default,
# (->Ignoresizeerrors attribute).  Admins are encouraged to
# --reindex for IMAP support, anyways.
sub emit_rfc822_size {
	my ($self, $k, $smsg) = @_;
	$self->msg_more(' RFC822.SIZE ' . $smsg->{bytes});
}

sub emit_internaldate {
	my ($self, undef, $smsg) = @_;
	$self->msg_more(' INTERNALDATE "'.$smsg->internaldate.'"');
}

sub emit_flags { $_[0]->msg_more(' FLAGS ()') }

sub emit_envelope {
	my ($self, undef, undef, undef, $eml) = @_;
	$self->msg_more(' ENVELOPE '.eml_envelope($eml));
}

sub emit_rfc822_header {
	my ($self, $k, undef, undef, $eml) = @_;
	$self->msg_more(" $k {".length(${$eml->{hdr}})."}\r\n");
	$self->msg_more(${$eml->{hdr}});
}

# n.b. this is sorted to be after any emit_eml_new ops
sub emit_rfc822_text {
	my ($self, $k, undef, $bref) = @_;
	$self->msg_more(" $k {".length($$bref)."}\r\n");
	$self->msg_more($$bref);
}

sub emit_bodystructure {
	my ($self, undef, undef, undef, $eml) = @_;
	$self->msg_more(' BODYSTRUCTURE '.fetch_body($eml, 1));
}

sub emit_body {
	my ($self, undef, undef, undef, $eml) = @_;
	$self->msg_more(' BODY '.fetch_body($eml));
}

# set $eml once ($_[4] == $eml, $_[3] == $bref)
sub op_eml_new { $_[4] = PublicInbox::Eml->new($_[3]) }

# s/From / fixes old bug from import (pre-a0c07cba0e5d8b6a)
sub to_crlf_full {
	${$_[0]} =~ s/(?<!\r)\n/\r\n/sg;
	${$_[0]} =~ s/\A[\r\n]*From [^\r\n]*\r\n//s;
}

sub op_crlf_bref { to_crlf_full($_[3]) }

sub op_crlf_hdr { to_crlf_full($_[4]->{hdr}) }

sub op_crlf_bdy { ${$_[4]->{bdy}} =~ s/(?<!\r)\n/\r\n/sg if $_[4]->{bdy} }

sub uid_clamp ($$$) {
	my ($self, $beg, $end) = @_;
	my $uid_min = $self->{uid_base} + 1;
	my $uid_end = $uid_min + UID_SLICE - 1;
	$$beg = $uid_min if $$beg < $uid_min;
	$$end = $uid_end if $$end > $uid_end;
}

sub range_step ($$) {
	my ($self, $range_csv) = @_;
	my ($beg, $end, $range);
	if ($$range_csv =~ s/\A([^,]+),//) {
		$range = $1;
	} else {
		$range = $$range_csv;
		$$range_csv = undef;
	}
	my $uid_base = $self->{uid_base};
	my $uid_end = $uid_base + UID_SLICE;
	if ($range =~ /\A([0-9]+):([0-9]+)\z/) {
		($beg, $end) = ($1 + 0, $2 + 0);
		uid_clamp($self, \$beg, \$end);
	} elsif ($range =~ /\A([0-9]+):\*\z/) {
		$beg = $1 + 0;
		$end = $self->{ibx}->over(1)->max;
		$end = $uid_end if $end > $uid_end;
		$beg = $end if $beg > $end;
		uid_clamp($self, \$beg, \$end);
	} elsif ($range =~ /\A[0-9]+\z/) {
		$beg = $end = $range + 0;
		# just let the caller do an out-of-range query if a single
		# UID is out-of-range
		++$beg if ($beg <= $uid_base || $end > $uid_end);
	} else {
		return 'BAD fetch range';
	}
	[ $beg, $end, $$range_csv ];
}

sub refill_range ($$$) {
	my ($self, $msgs, $range_info) = @_;
	my ($beg, $end, $range_csv) = @$range_info;
	if (scalar(@$msgs = @{$self->{ibx}->over(1)->query_xover($beg, $end)})){
		$range_info->[0] = $msgs->[-1]->{num} + 1;
		return;
	}
	return 'OK Fetch done' if !$range_csv;
	my $next_range = range_step($self, \$range_csv);
	return $next_range if !ref($next_range); # error
	@$range_info = @$next_range;
	undef; # keep looping
}

sub fetch_blob { # long_response
	my ($self, $tag, $msgs, $range_info, $ops, $partial) = @_;
	while (!@$msgs) { # rare
		if (my $end = refill_range($self, $msgs, $range_info)) {
			$self->write(\"$tag $end\r\n");
			return;
		}
	}
	uo2m_extend($self, $msgs->[-1]->{num});
	ibx_async_cat($self->{ibx}, $msgs->[0]->{blob},
			\&fetch_blob_cb, \@_);
}

sub fetch_smsg { # long_response
	my ($self, $tag, $msgs, $range_info, $ops) = @_;
	while (!@$msgs) { # rare
		if (my $end = refill_range($self, $msgs, $range_info)) {
			$self->write(\"$tag $end\r\n");
			return;
		}
	}
	uo2m_extend($self, $msgs->[-1]->{num});
	fetch_run_ops($self, $_, undef, $ops) for @$msgs;
	@$msgs = ();
	1; # more
}

sub refill_uids ($$$;$) {
	my ($self, $uids, $range_info, $sql) = @_;
	my ($beg, $end, $range_csv) = @$range_info;
	my $over = $self->{ibx}->over(1);
	while (1) {
		if (scalar(@$uids = @{$over->uid_range($beg, $end, $sql)})) {
			$range_info->[0] = $uids->[-1] + 1; # update $beg
			return;
		} elsif (!$range_csv) {
			return 0;
		} else {
			my $next_range = range_step($self, \$range_csv);
			return $next_range if !ref($next_range); # error
			($beg, $end, $range_csv) = @$range_info = @$next_range;
			# continue looping
		}
	}
}

sub fetch_uid { # long_response
	my ($self, $tag, $uids, $range_info, $ops) = @_;
	if (defined(my $err = refill_uids($self, $uids, $range_info))) {
		$err ||= 'OK Fetch done';
		$self->write("$tag $err\r\n");
		return;
	}
	my $adj = $self->{uid_base} + 1;
	my $uo2m = uo2m_extend($self, $uids->[-1]);
	$uo2m = [ unpack('S*', $uo2m) ] if !ref($uo2m);
	my ($i, $k);
	for (@$uids) {
		$self->msg_more("* $uo2m->[$_ - $adj] FETCH (UID $_");
		for ($i = 0; $i < @$ops;) {
			$k = $ops->[$i++];
			$ops->[$i++]->($self, $k);
		}
		$self->msg_more(")\r\n");
	}
	@$uids = ();
	1; # more
}

sub cmd_status ($$$;@) {
	my ($self, $tag, $mailbox, @items) = @_;
	return "$tag BAD no items\r\n" if !scalar(@items);
	($items[0] !~ s/\A\(//s || $items[-1] !~ s/\)\z//s) and
		return "$tag BAD invalid args\r\n";
	my ($ibx, $exists, $uidnext) = inbox_lookup($self, $mailbox);
	return "$tag NO Mailbox doesn't exist: $mailbox\r\n" if !$ibx;
	my @it;
	for my $it (@items) {
		$it = uc($it);
		push @it, $it;
		if ($it =~ /\A(?:MESSAGES|UNSEEN|RECENT)\z/) {
			push @it, $exists;
		} elsif ($it eq 'UIDNEXT') {
			push @it, $uidnext;
		} elsif ($it eq 'UIDVALIDITY') {
			push @it, $ibx->{uidvalidity};
		} else {
			return "$tag BAD invalid item\r\n";
		}
	}
	return "$tag BAD no items\r\n" if !@it;
	"* STATUS $mailbox (".join(' ', @it).")\r\n" .
	"$tag OK Status done\r\n";
}

my %patmap = ('*' => '.*', '%' => '[^\.]*');
sub cmd_list ($$$$) {
	my ($self, $tag, $refname, $wildcard) = @_;
	my $l = $self->{imapd}->{mailboxlist};
	if ($refname eq '' && $wildcard eq '') {
		# request for hierarchy delimiter
		$l = [ qq[* LIST (\\Noselect) "." ""\r\n] ];
	} elsif ($refname ne '' || $wildcard ne '*') {
		$wildcard =~ s!([^a-z0-9_])!$patmap{$1} // "\Q$1"!egi;
		$l = [ grep(/ \Q$refname\E$wildcard\r\n\z/is, @$l) ];
	}
	\(join('', @$l, "$tag OK List done\r\n"));
}

sub cmd_lsub ($$$$) {
	my (undef, $tag) = @_; # same args as cmd_list
	"$tag OK Lsub done\r\n";
}

sub eml_index_offs_i { # PublicInbox::Eml::each_part callback
	my ($p, $all) = @_;
	my ($eml, undef, $idx) = @$p;
	if ($idx && lc($eml->ct->{type}) eq 'multipart') {
		$eml->{imap_bdy} = $eml->{bdy} // \'';
	}
	$all->{$idx} = $eml; # $idx => Eml
}

# prepares an index for BODY[$SECTION_IDX] fetches
sub eml_body_idx ($$) {
	my ($eml, $section_idx) = @_;
	my $idx = $eml->{imap_all_parts} // do {
		my $all = {};
		$eml->each_part(\&eml_index_offs_i, $all, 0, 1);
		# top-level of multipart, BODY[0] not allowed (nz-number)
		delete $all->{0};
		$eml->{imap_all_parts} = $all;
	};
	$idx->{$section_idx};
}

# BODY[($SECTION_IDX)?(.$SECTION_NAME)?]<$offset.$bytes>
sub partial_body {
	my ($eml, $section_idx, $section_name) = @_;
	if (defined $section_idx) {
		$eml = eml_body_idx($eml, $section_idx) or return;
	}
	if (defined $section_name) {
		if ($section_name eq 'MIME') {
			# RFC 3501 6.4.5 states:
			#	The MIME part specifier MUST be prefixed
			#	by one or more numeric part specifiers
			return unless defined $section_idx;
			return $eml->header_obj->as_string . "\r\n";
		}
		my $bdy = $eml->{bdy} // $eml->{imap_bdy} // \'';
		$eml = PublicInbox::Eml->new($$bdy);
		if ($section_name eq 'TEXT') {
			return $eml->body_raw;
		} elsif ($section_name eq 'HEADER') {
			return $eml->header_obj->as_string . "\r\n";
		} else {
			die "BUG: bad section_name=$section_name";
		}
	}
	${$eml->{bdy} // $eml->{imap_bdy} // \''};
}

# similar to what's in PublicInbox::Eml::re_memo, but doesn't memoize
# to avoid OOM with malicious users
sub hdrs_regexp ($) {
	my ($hdrs) = @_;
	my $names = join('|', map { "\Q$_" } split(/[ \t]+/, $hdrs));
	qr/^(?:$names):[ \t]*[^\n]*\r?\n # 1st line
		# continuation lines:
		(?:[^:\n]*?[ \t]+[^\n]*\r?\n)*
		/ismx;
}

# BODY[($SECTION_IDX.)?HEADER.FIELDS.NOT ($HDRS)]<$offset.$bytes>
sub partial_hdr_not {
	my ($eml, $section_idx, $hdrs_re) = @_;
	if (defined $section_idx) {
		$eml = eml_body_idx($eml, $section_idx) or return;
	}
	my $str = $eml->header_obj->as_string;
	$str =~ s/$hdrs_re//g;
	$str =~ s/(?<!\r)\n/\r\n/sg;
	$str .= "\r\n";
}

# BODY[($SECTION_IDX.)?HEADER.FIELDS ($HDRS)]<$offset.$bytes>
sub partial_hdr_get {
	my ($eml, $section_idx, $hdrs_re) = @_;
	if (defined $section_idx) {
		$eml = eml_body_idx($eml, $section_idx) or return;
	}
	my $str = $eml->header_obj->as_string;
	$str = join('', ($str =~ m/($hdrs_re)/g));
	$str =~ s/(?<!\r)\n/\r\n/sg;
	$str .= "\r\n";
}

sub partial_prepare ($$$$) {
	my ($need, $partial, $want, $att) = @_;

	# recombine [ "BODY[1.HEADER.FIELDS", "(foo", "bar)]" ]
	# back to: "BODY[1.HEADER.FIELDS (foo bar)]"
	return unless $att =~ /\ABODY\[/s;
	until (rindex($att, ']') >= 0) {
		my $next = shift @$want or return;
		$att .= ' ' . uc($next);
	}
	if ($att =~ /\ABODY\[([0-9]+(?:\.[0-9]+)*)? # 1 - section_idx
			(?:\.(HEADER|MIME|TEXT))? # 2 - section_name
			\](?:<([0-9]+)(?:\.([0-9]+))?>)?\z/sx) { # 3, 4
		$partial->{$att} = [ \&partial_body, $1, $2, $3, $4 ];
		$$need |= CRLF_BREF|EML_HDR|EML_BDY;
	} elsif ($att =~ /\ABODY\[(?:([0-9]+(?:\.[0-9]+)*)\.)? # 1 - section_idx
				(?:HEADER\.FIELDS(\.NOT)?)\x20 # 2
				\(([A-Z0-9\-\x20]+)\) # 3 - hdrs
			\](?:<([0-9]+)(?:\.([0-9]+))?>)?\z/sx) { # 4 5
		my $tmp = $partial->{$att} = [ $2 ? \&partial_hdr_not
						: \&partial_hdr_get,
						$1, undef, $4, $5 ];
		$tmp->[2] = hdrs_regexp($3);

		# don't emit CRLF_HDR instruction, here, partial_hdr_*
		# will do CRLF conversion with only the extracted result
		# and not waste time converting lines we don't care about.
		$$need |= EML_HDR;
	} else {
		undef;
	}
}

sub partial_emit ($$$) {
	my ($self, $partial, $eml) = @_;
	for (@$partial) {
		my ($k, $cb, @args) = @$_;
		my ($offset, $len) = splice(@args, -2);
		# $cb is partial_body|partial_hdr_get|partial_hdr_not
		my $str = $cb->($eml, @args) // '';
		if (defined $offset) {
			if (defined $len) {
				$str = substr($str, $offset, $len);
				$k =~ s/\.$len>\z/>/ or warn
"BUG: unable to remove `.$len>' from `$k'";
			} else {
				$str = substr($str, $offset);
				$len = length($str);
			}
		} else {
			$len = length($str);
		}
		$self->msg_more(" $k {$len}\r\n");
		$self->msg_more($str);
	}
}

sub fetch_compile ($) {
	my ($want) = @_;
	if ($want->[0] =~ s/\A\(//s) {
		$want->[-1] =~ s/\)\z//s or return 'BAD no rparen';
	}
	my (%partial, %seen, @op);
	my $need = 0;
	while (defined(my $att = shift @$want)) {
		$att = uc($att);
		next if $att eq 'UID'; # always returned
		$att =~ s/\ABODY\.PEEK\[/BODY\[/; # we're read-only
		my $x = $FETCH_ATT{$att};
		if ($x) {
			while (my ($k, $fl_cb) = each %$x) {
				next if $seen{$k}++;
				$need |= $fl_cb->[0];
				push @op, [ @$fl_cb, $k ];
			}
		} elsif (!partial_prepare(\$need, \%partial, $want, $att)) {
			return "BAD param: $att";
		}
	}
	my @r;

	# stabilize partial order for consistency and ease-of-debugging:
	if (scalar keys %partial) {
		$need |= NEED_BLOB;
		$r[2] = [ map { [ $_, @{$partial{$_}} ] } sort keys %partial ];
	}

	push @op, $OP_EML_NEW if ($need & (EML_HDR|EML_BDY));

	# do we need CRLF conversion?
	if ($need & CRLF_BREF) {
		push @op, $OP_CRLF_BREF;
	} elsif (my $crlf = ($need & (CRLF_HDR|CRLF_BDY))) {
		if ($crlf == (CRLF_HDR|CRLF_BDY)) {
			push @op, $OP_CRLF_BREF;
		} elsif ($need & CRLF_HDR) {
			push @op, $OP_CRLF_HDR;
		} else {
			push @op, $OP_CRLF_BDY;
		}
	}

	$r[0] = $need & NEED_BLOB ? \&fetch_blob :
		($need & NEED_SMSG ? \&fetch_smsg : \&fetch_uid);

	# r[1] = [ $key1, $cb1, $key2, $cb2, ... ]
	use sort 'stable'; # makes output more consistent
	$r[1] = [ map { ($_->[2], $_->[1]) } sort { $a->[0] <=> $b->[0] } @op ];
	@r;
}

sub cmd_uid_fetch ($$$$;@) {
	my ($self, $tag, $range_csv, @want) = @_;
	my $ibx = $self->{ibx} or return "$tag BAD No mailbox selected\r\n";
	my ($cb, $ops, $partial) = fetch_compile(\@want);
	return "$tag $cb\r\n" unless $ops;

	# cb is one of fetch_blob, fetch_smsg, fetch_uid
	$range_csv = 'bad' if $range_csv !~ $valid_range;
	my $range_info = range_step($self, \$range_csv);
	return "$tag $range_info\r\n" if !ref($range_info);
	uo2m_hibernate($self) if $cb == \&fetch_blob; # slow, save RAM
	long_response($self, $cb, $tag, [], $range_info, $ops, $partial);
}

sub cmd_fetch ($$$$;@) {
	my ($self, $tag, $range_csv, @want) = @_;
	my $ibx = $self->{ibx} or return "$tag BAD No mailbox selected\r\n";
	my ($cb, $ops, $partial) = fetch_compile(\@want);
	return "$tag $cb\r\n" unless $ops;

	# cb is one of fetch_blob, fetch_smsg, fetch_uid
	$range_csv = 'bad' if $range_csv !~ $valid_range;
	msn_to_uid_range(msn2uid($self), $range_csv);
	my $range_info = range_step($self, \$range_csv);
	return "$tag $range_info\r\n" if !ref($range_info);
	uo2m_hibernate($self) if $cb == \&fetch_blob; # slow, save RAM
	long_response($self, $cb, $tag, [], $range_info, $ops, $partial);
}

sub msn_convert ($$) {
	my ($self, $uids) = @_;
	my $adj = $self->{uid_base} + 1;
	my $uo2m = uo2m_extend($self, $uids->[-1]);
	$uo2m = [ unpack('S*', $uo2m) ] if !ref($uo2m);
	$_ = $uo2m->[$_ - $adj] for @$uids;
}

sub search_uid_range { # long_response
	my ($self, $tag, $sql, $range_info, $want_msn) = @_;
	my $uids = [];
	if (defined(my $err = refill_uids($self, $uids, $range_info, $sql))) {
		$err ||= 'OK Search done';
		$self->write("\r\n$tag $err\r\n");
		return;
	}
	msn_convert($self, $uids) if $want_msn;
	$self->msg_more(join(' ', '', @$uids));
	1; # more
}

sub parse_imap_query ($$) {
	my ($self, $query) = @_;
	my $q = PublicInbox::IMAPsearchqp::parse($self, $query);
	if (ref($q)) {
		my $max = $self->{ibx}->over(1)->max;
		my $beg = 1;
		uid_clamp($self, \$beg, \$max);
		$q->{range_info} = [ $beg, $max ];
	}
	$q;
}

sub search_common {
	my ($self, $tag, $query, $want_msn) = @_;
	my $ibx = $self->{ibx} or return "$tag BAD No mailbox selected\r\n";
	my $q = parse_imap_query($self, $query);
	return "$tag $q\r\n" if !ref($q);
	my ($sql, $range_info) = delete @$q{qw(sql range_info)};
	if (!scalar(keys %$q)) { # overview.sqlite3
		$self->msg_more('* SEARCH');
		long_response($self, \&search_uid_range,
				$tag, $sql, $range_info, $want_msn);
	} elsif ($q = $q->{xap}) {
		my $srch = $self->{ibx}->isrch or
			return "$tag BAD search not available for mailbox\r\n";
		my $opt = {
			relevance => -1,
			limit => UID_SLICE,
			uid_range => $range_info
		};
		my $mset = $srch->mset($q, $opt);
		my $uids = $srch->mset_to_artnums($mset, $opt);
		msn_convert($self, $uids) if scalar(@$uids) && $want_msn;
		"* SEARCH @$uids\r\n$tag OK Search done\r\n";
	} else {
		"$tag BAD Error\r\n";
	}
}

sub cmd_uid_search ($$$) {
	my ($self, $tag, $query) = @_;
	search_common($self, $tag, $query);
}

sub cmd_search ($$$;) {
	my ($self, $tag, $query) = @_;
	search_common($self, $tag, $query, 1);
}

# returns 1 if we can continue, 0 if not due to buffered writes or disconnect
sub process_line ($$) {
	my ($self, $l) = @_;

	# TODO: IMAP allows literals for big requests to upload messages
	# (which we don't support) but maybe some big search queries use it.
	# RFC 3501 9 (2) doesn't permit TAB or multiple SP
	my ($tag, $req, @args) = parse_line('[ \t]+', 0, $l);
	pop(@args) if (@args && !defined($args[-1]));
	if (@args && uc($req) eq 'UID') {
		$req .= "_".(shift @args);
	}
	my $res = eval {
		if (defined(my $idle_tag = $self->{-idle_tag})) {
			(uc($tag // '') eq 'DONE' && !defined($req)) ?
				idle_done($self, $tag) :
				"$idle_tag BAD expected DONE\r\n";
		} elsif (my $cmd = $self->can('cmd_'.lc($req // ''))) {
			if ($cmd == \&cmd_uid_search || $cmd == \&cmd_search) {
				# preserve user-supplied quotes for search
				(undef, @args) = split(/ search /i, $l, 2);
			}
			$cmd->($self, $tag, @args);
		} else { # this is weird
			auth_challenge_ok($self) //
					($tag // '*') .
					' BAD Error in IMAP command '.
					($req // '(???)').
					": Unknown command\r\n";
		}
	};
	my $err = $@;
	if ($err && $self->{sock}) {
		$l =~ s/\r?\n//s;
		err($self, 'error from: %s (%s)', $l, $err);
		$tag //= '*';
		$res = "$tag BAD program fault - command not performed\r\n";
	}
	return 0 unless defined $res;
	$self->write($res);
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

sub err ($$;@) {
	my ($self, $fmt, @args) = @_;
	printf { $self->{imapd}->{err} } $fmt."\n", @args;
}

sub out ($$;@) {
	my ($self, $fmt, @args) = @_;
	printf { $self->{imapd}->{out} } $fmt."\n", @args;
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

# callback used by PublicInbox::DS for any (e)poll (in/out/hup/err)
sub event_step {
	my ($self) = @_;

	return unless $self->flush_write && $self->{sock} && !$self->{long_cb};

	# only read more requests if we've drained the write buffer,
	# otherwise we can be buffering infinitely w/o backpressure

	my $rbuf = $self->{rbuf} // \(my $x = '');
	my $line = index($$rbuf, "\n");
	while ($line < 0) {
		if (length($$rbuf) >= LINE_MAX) {
			$self->write(\"\* BAD request too long\r\n");
			return $self->close;
		}
		$self->do_read($rbuf, LINE_MAX, length($$rbuf)) or
				return uo2m_hibernate($self);
		$line = index($$rbuf, "\n");
	}
	$line = substr($$rbuf, 0, $line + 1, '');
	$line =~ s/\r?\n\z//s;
	return $self->close if $line =~ /[[:cntrl:]]/s;
	my $t0 = now();
	my $fd = fileno($self->{sock});
	my $r = eval { process_line($self, $line) };
	my $pending = $self->{wbuf} ? ' pending' : '';
	out($self, "[$fd] %s - %0.6f$pending - $r", $line, now() - $t0);

	return $self->close if $r < 0;
	$self->rbuf_idle($rbuf);

	# maybe there's more pipelined data, or we'll have
	# to register it for socket-readiness notifications
	$self->requeue unless $pending;
}

sub compressed { undef }

# RFC 4978
sub cmd_compress ($$$) {
	my ($self, $tag, $alg) = @_;
	return "$tag BAD DEFLATE only\r\n" if uc($alg) ne "DEFLATE";
	return "$tag BAD COMPRESS active\r\n" if $self->compressed;

	# CRIME made TLS compression obsolete
	# return "$tag NO [COMPRESSIONACTIVE]\r\n" if $self->tls_compressed;

	PublicInbox::IMAPdeflate->enable($self, $tag);
	$self->requeue;
	undef
}

sub cmd_starttls ($$) {
	my ($self, $tag) = @_;
	my $sock = $self->{sock} or return;
	if ($sock->can('stop_SSL') || $self->compressed) {
		return "$tag BAD TLS or compression already enabled\r\n";
	}
	my $opt = $self->{imapd}->{accept_tls} or
		return "$tag BAD can not initiate TLS negotiation\r\n";
	$self->write(\"$tag OK begin TLS negotiation now\r\n");
	$self->{sock} = IO::Socket::SSL->start_SSL($sock, %$opt);
	$self->requeue if PublicInbox::DS::accept_tls_step($self);
	undef;
}

sub busy { # for graceful shutdown in PublicInbox::Daemon:
	my ($self) = @_;
	if (defined($self->{-idle_tag})) {
		$self->write(\"* BYE server shutting down\r\n");
		return; # not busy anymore
	}
	defined($self->{rbuf}) || defined($self->{wbuf}) ||
		!$self->write(\"* BYE server shutting down\r\n");
}

sub close {
	my ($self) = @_;
	if (my $ibx = delete $self->{ibx}) {
		stop_idle($self, $ibx);
	}
	$self->SUPER::close; # PublicInbox::DS::close
}

# we're read-only, so SELECT and EXAMINE do the same thing
no warnings 'once';
*cmd_select = \&cmd_examine;

package PublicInbox::IMAP_preauth;
our @ISA = qw(PublicInbox::IMAP);

sub logged_in { 0 }

1;
