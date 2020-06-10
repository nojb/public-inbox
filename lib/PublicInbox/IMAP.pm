# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Each instance of this represents an IMAP client connected to
# public-inbox-imapd.  Much of this was taken from NNTP, but
# further refined while experimenting on future ideas to handle
# slow storage.
#
# data notes:
# * NNTP article numbers are UIDs and message sequence numbers (MSNs)
# * Message sequence numbers (MSNs) can be stable since we're read-only.
#   Most IMAP clients use UIDs (I hope).  We may return a dummy message
#   in the future if a client requests a non-existent MSN, but that seems
#   unecessary with mutt.

package PublicInbox::IMAP;
use strict;
use base qw(PublicInbox::DS);
use fields qw(imapd ibx long_cb -login_tag
	uid_min -idle_tag -idle_max);
use PublicInbox::Eml;
use PublicInbox::EmlContentFoo qw(parse_content_disposition);
use PublicInbox::DS qw(now);
use PublicInbox::Syscall qw(EPOLLIN EPOLLONESHOT);
use PublicInbox::GitAsyncCat;
use Text::ParseWords qw(parse_line);
use Errno qw(EAGAIN);
use Time::Local qw(timegm);
use POSIX qw(strftime);
use Hash::Util qw(unlock_hash); # dependency of fields for perl 5.10+, anyways

my $Address;
for my $mod (qw(Email::Address::XS Mail::Address)) {
	eval "require $mod" or next;
	$Address = $mod and last;
}
die "neither Email::Address::XS nor Mail::Address loaded: $@" if !$Address;

sub LINE_MAX () { 512 } # does RFC 3501 have a limit like RFC 977?

# changing this will cause grief for clients which cache
sub UID_BLOCK () { 50_000 }

# these values area also used for sorting
sub NEED_SMSG () { 1 }
sub NEED_BLOB () { NEED_SMSG|2 }
sub NEED_EML () { NEED_BLOB|4 }
my $OP_EML_NEW = [ NEED_EML - 1, \&op_eml_new ];

my %FETCH_NEED = (
	'BODY[HEADER]' => [ NEED_EML, \&emit_rfc822_header ],
	'BODY[TEXT]' => [ NEED_EML, \&emit_rfc822_text ],
	'BODY[]' => [ NEED_BLOB, \&emit_rfc822 ],
	'RFC822.HEADER' => [ NEED_EML, \&emit_rfc822_header ],
	'RFC822.TEXT' => [ NEED_EML, \&emit_rfc822_text ],
	'RFC822.SIZE' => [ NEED_SMSG, \&emit_rfc822_size ],
	RFC822 => [ NEED_BLOB, \&emit_rfc822 ],
	BODY => [ NEED_EML, \&emit_body ],
	BODYSTRUCTURE => [ NEED_EML, \&emit_bodystructure ],
	ENVELOPE => [ NEED_EML, \&emit_envelope ],
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

my @MoY = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
my %MoY;
@MoY{@MoY} = (0..11);

# RFC 3501 5.4. Autologout Timer needs to be >= 30min
$PublicInbox::DS::EXPTIME = 60 * 30;

sub greet ($) {
	my ($self) = @_;
	my $capa = capa($self);
	$self->write(\"* OK [$capa] public-inbox-imapd ready\r\n");
}

sub new ($$$) {
	my ($class, $sock, $imapd) = @_;
	my $self = fields::new('PublicInbox::IMAP_preauth');
	unlock_hash(%$self);
	my $ev = EPOLLIN;
	my $wbuf;
	if ($sock->can('accept_SSL') && !$sock->accept_SSL) {
		return CORE::close($sock) if $! != EAGAIN;
		$ev = PublicInbox::TLS::epollbit();
		$wbuf = [ \&PublicInbox::DS::accept_tls_step, \&greet ];
	}
	$self->SUPER::new($sock, $ev | EPOLLONESHOT);
	$self->{imapd} = $imapd;
	if ($wbuf) {
		$self->{wbuf} = $wbuf;
	} else {
		greet($self);
	}
	$self->update_idle_time;
	$self;
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
	delete $self->{uid_min};
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

sub cmd_noop ($$) { "$_[1] OK Noop done\r\n" }

# called by PublicInbox::InboxIdle
sub on_inbox_unlock {
	my ($self, $ibx) = @_;
	my $new = $ibx->mm->max;
	my $uid_end = ($self->{uid_min} // 1) - 1 + UID_BLOCK;
	defined(my $old = $self->{-idle_max}) or die 'BUG: -idle_max unset';
	$new = $uid_end if $new > $uid_end;
	if ($new > $old) {
		$self->{-idle_max} = $new;
		$self->msg_more("* $_ EXISTS\r\n") for (($old + 1)..($new - 1));
		$self->write(\"* $new EXISTS\r\n");
	} elsif ($new == $uid_end) { # max exceeded $uid_end
		# continue idling w/o inotify
		delete $self->{-idle_max};
		my $sock = $self->{sock} or return;
		$ibx->unsubscribe_unlock(fileno($sock));
	}
}

# called every X minute(s) or so by PublicInbox::DS::later
my $IDLERS = {};
my $idle_timer;
sub idle_tick_all {
	my $old = $IDLERS;
	$IDLERS = {};
	for my $i (values %$old) {
		next if ($i->{wbuf} || !exists($i->{-idle_tag}));
		$i->update_idle_time or next;
		$IDLERS->{fileno($i->{sock})} = $i;
		$i->write(\"* OK Still here\r\n");
	}
	$idle_timer = scalar keys %$IDLERS ?
			PublicInbox::DS::later(\&idle_tick_all) : undef;
}

sub cmd_idle ($$) {
	my ($self, $tag) = @_;
	# IDLE seems allowed by dovecot w/o a mailbox selected *shrug*
	my $ibx = $self->{ibx} or return "$tag BAD no mailbox selected\r\n";
	$self->{-idle_tag} = $tag;
	my $max = $ibx->mm->max // 0;
	my $uid_end = ($self->{uid_min} // 1) - 1 + UID_BLOCK;
	my $sock = $self->{sock} or return;
	my $fd = fileno($sock);
	# only do inotify on most recent slice
	if ($max < $uid_end) {
		$ibx->subscribe_unlock($fd, $self);
		$self->{imapd}->idler_start;
		$self->{-idle_max} = $max;
	}
	$idle_timer //= PublicInbox::DS::later(\&idle_tick_all);
	$IDLERS->{$fd} = $self;
	\"+ idling\r\n"
}

sub stop_idle ($$) {
	my ($self, $ibx);
	my $sock = $self->{sock} or return;
	my $fd = fileno($sock);
	delete $IDLERS->{$fd};
	$ibx->unsubscribe_unlock($fd);
}

sub cmd_done ($$) {
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

sub ensure_ranges_exist ($$$) {
	my ($imapd, $ibx, $max) = @_;
	my $mailboxes = $imapd->{mailboxes};
	my $mb_top = $ibx->{newsgroup};
	my @created;
	for (my $i = int($max/UID_BLOCK); $i >= 0; --$i) {
		my $sub_mailbox = "$mb_top.$i";
		last if exists $mailboxes->{$sub_mailbox};
		$mailboxes->{$sub_mailbox} = $ibx;
		push @created, $sub_mailbox;
	}
	return unless @created;
	my $l = $imapd->{inboxlist} or return;
	push @$l, map { qq[* LIST (\\HasNoChildren) "." $_\r\n] } @created;
}

sub inbox_lookup ($$) {
	my ($self, $mailbox) = @_;
	my ($ibx, $exists, $uidnext);
	if ($mailbox =~ /\A(.+)\.([0-9]+)\z/) {
		# old mail: inbox.comp.foo.$uid_block_idx
		my ($mb_top, $uid_min) = ($1, $2 * UID_BLOCK + 1);

		$ibx = $self->{imapd}->{mailboxes}->{lc $mailbox} or return;
		$exists = $ibx->mm->max // 0;
		$self->{uid_min} = $uid_min;
		ensure_ranges_exist($self->{imapd}, $ibx, $exists);
		my $uid_end = $uid_min + UID_BLOCK - 1;
		$exists = $uid_end if $exists > $uid_end;
		$uidnext = $exists + 1;
	} else { # check for dummy inboxes
		$ibx = $self->{imapd}->{mailboxes}->{lc $mailbox} or return;
		delete $self->{uid_min};
		$exists = 0;
		$uidnext = 1;
	}
	($ibx, $exists, $uidnext);
}

sub cmd_examine ($$$) {
	my ($self, $tag, $mailbox) = @_;
	my ($ibx, $exists, $uidnext) = inbox_lookup($self, $mailbox);
	return "$tag NO Mailbox doesn't exist: $mailbox\r\n" if !$ibx;

	# XXX: do we need this? RFC 5162/7162
	my $ret = $self->{ibx} ? "* OK [CLOSED] previous closed\r\n" : '';
	$self->{ibx} = $ibx;
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
	$buf .= ' ' . _esc_hash(delete $cd->{attributes});
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
	$buf .= ' ' . _esc_hash(delete $ct->{attributes});
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
			$buf .= ' '._esc_hash(delete $ct->{attributes});
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

sub uid_fetch_cb { # called by git->cat_async via git_async_cat
	my ($bref, $oid, $type, $size, $fetch_m_arg) = @_;
	my ($self, undef, $msgs, undef, $ops, $partial) = @$fetch_m_arg;
	my $smsg = shift @$msgs or die 'BUG: no smsg';
	if (!defined($oid)) {
		# it's possible to have TOCTOU if an admin runs
		# public-inbox-(edit|purge), just move onto the next message
		return requeue_once($self);
	} else {
		$smsg->{blob} eq $oid or die "BUG: $smsg->{blob} != $oid";
	}
	$$bref =~ s/(?<!\r)\n/\r\n/sg; # make strict clients happy

	# fixup old bug from import (pre-a0c07cba0e5d8b6a)
	$$bref =~ s/\A[\r\n]*From [^\r\n]*\r\n//s;
	$self->msg_more("* $smsg->{num} FETCH (UID $smsg->{num}");
	my $eml;
	for (my $i = 0; $i < @$ops;) {
		my $k = $ops->[$i++];
		$ops->[$i++]->($self, $k, $smsg, $bref, $eml);
	}
	partial_emit($self, $partial, $eml) if $partial;
	$self->msg_more(")\r\n");
	requeue_once($self);
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

sub uid_clamp ($$$) {
	my ($self, $beg, $end) = @_;
	my $uid_min = $self->{uid_min} or return;
	my $uid_end = $uid_min + UID_BLOCK - 1;
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
	if ($range =~ /\A([0-9]+):([0-9]+)\z/) {
		($beg, $end) = ($1 + 0, $2 + 0);
	} elsif ($range =~ /\A([0-9]+):\*\z/) {
		$beg = $1 + 0;
		$end = $self->{ibx}->mm->max // 0;
		my $uid_end = ($self->{uid_min} // 1) - 1 + UID_BLOCK;
		$end = $uid_end if $end > $uid_end;
		$beg = $end if $beg > $end;
	} elsif ($range =~ /\A[0-9]+\z/) {
		$beg = $end = $range + 0;
		undef $range;
	} else {
		return 'BAD fetch range';
	}
	uid_clamp($self, \$beg, \$end) if defined($range);
	[ $beg, $end, $$range_csv ];
}

sub refill_range ($$$) {
	my ($self, $msgs, $range_info) = @_;
	my ($beg, $end, $range_csv) = @$range_info;
	if (scalar(@$msgs = @{$self->{ibx}->over->query_xover($beg, $end)})) {
		$range_info->[0] = $msgs->[-1]->{num} + 1;
		return;
	}
	return 'OK Fetch done' if !$range_csv;
	my $next_range = range_step($self, \$range_csv);
	return $next_range if !ref($next_range); # error
	@$range_info = @$next_range;
	undef; # keep looping
}

sub uid_fetch_msg { # long_response
	my ($self, $tag, $msgs, $range_info) = @_; # \@ops, \@partial
	while (!@$msgs) { # rare
		if (my $end = refill_range($self, $msgs, $range_info)) {
			$self->write(\"$tag $end\r\n");
			return;
		}
	}
	git_async_cat($self->{ibx}->git, $msgs->[0]->{blob},
			\&uid_fetch_cb, \@_);
}

sub uid_fetch_smsg { # long_response
	my ($self, $tag, $msgs, $range_info, $ops) = @_;
	while (!@$msgs) { # rare
		if (my $end = refill_range($self, $msgs, $range_info)) {
			$self->write(\"$tag $end\r\n");
			return;
		}
	}
	for my $smsg (@$msgs) {
		$self->msg_more("* $smsg->{num} FETCH (UID $smsg->{num}");
		for (my $i = 0; $i < @$ops;) {
			my $k = $ops->[$i++];
			$ops->[$i++]->($self, $k, $smsg);
		}
		$self->msg_more(")\r\n");
	}
	@$msgs = ();
	1; # more
}

sub uid_fetch_uid { # long_response
	my ($self, $tag, $uids, $range_info, $ops) = @_;
	while (!@$uids) { # rare
		my ($beg, $end, $range_csv) = @$range_info;
		if (scalar(@$uids = @{$self->{ibx}->over->
					uid_range($beg, $end)})) {
			$range_info->[0] = $uids->[-1] + 1;
		} elsif (!$range_csv) {
			$self->write(\"$tag OK Fetch done\r\n");
			return;
		} else {
			my $next_range = range_step($self, \$range_csv);
			if (!ref($next_range)) { # error
				$self->write(\"$tag $next_range\r\n");
				return;
			}
			@$range_info = @$next_range;
		}
		# continue looping
	}
	for (@$uids) {
		$self->msg_more("* $_ FETCH (UID $_");
		for (my $i = 0; $i < @$ops;) {
			my $k = $ops->[$i++];
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
	my $l = $self->{imapd}->{inboxlist};
	if ($refname eq '' && $wildcard eq '') {
		# request for hierarchy delimiter
		$l = [ qq[* LIST (\\Noselect) "." ""\r\n] ];
	} elsif ($refname ne '' || $wildcard ne '*') {
		$wildcard = lc $wildcard;
		$wildcard =~ s!([^a-z0-9_])!$patmap{$1} // "\Q$1"!eg;
		$l = [ grep(/ \Q$refname\E$wildcard\r\n\z/s, @$l) ];
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
	my $idx = $eml->{imap_all_parts} //= do {
		my $all = {};
		$eml->each_part(\&eml_index_offs_i, $all, 0, 1);
		# top-level of multipart, BODY[0] not allowed (nz-number)
		delete $all->{0};
		$all;
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
	$str .= "\r\n";
}

# BODY[($SECTION_IDX.)?HEADER.FIELDS ($HDRS)]<$offset.$bytes>
sub partial_hdr_get {
	my ($eml, $section_idx, $hdrs_re) = @_;
	if (defined $section_idx) {
		$eml = eml_body_idx($eml, $section_idx) or return;
	}
	my $str = $eml->header_obj->as_string;
	join('', ($str =~ m/($hdrs_re)/g), "\r\n");
}

sub partial_prepare ($$$) {
	my ($partial, $want, $att) = @_;

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
	} elsif ($att =~ /\ABODY\[(?:([0-9]+(?:\.[0-9]+)*)\.)? # 1 - section_idx
				(?:HEADER\.FIELDS(\.NOT)?)\x20 # 2
				\(([A-Z0-9\-\x20]+)\) # 3 - hdrs
			\](?:<([0-9]+)(?:\.([0-9]+))?>)?\z/sx) { # 4 5
		my $tmp = $partial->{$att} = [ $2 ? \&partial_hdr_not
						: \&partial_hdr_get,
						$1, undef, $4, $5 ];
		$tmp->[2] = hdrs_regexp($3);
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

				# insert a special op to convert $bref to $eml
				# the first time we need it
				if ($need == NEED_EML && !$seen{$need}++) {
					push @op, $OP_EML_NEW;
				}
				# $fl_cb = [ flags, \&emit_foo ]
				push @op, [ @$fl_cb , $k ];
			}
		} elsif (!partial_prepare(\%partial, $want, $att)) {
			return "BAD param: $att";
		}
	}
	my @r;

	# stabilize partial order for consistency and ease-of-debugging:
	if (scalar keys %partial) {
		$need = NEED_EML;
		push @op, $OP_EML_NEW if !$seen{$need}++;
		$r[2] = [ map { [ $_, @{$partial{$_}} ] } sort keys %partial ];
	}

	$r[0] = $need & NEED_BLOB ? \&uid_fetch_msg :
		($need & NEED_SMSG ? \&uid_fetch_smsg : \&uid_fetch_uid);

	# r[1] = [ $key1, $cb1, $key2, $cb2, ... ]
	use sort 'stable'; # makes output more consistent
	$r[1] = [ map { ($_->[2], $_->[1]) } sort { $a->[0] <=> $b->[0] } @op ];
	@r;
}

sub cmd_uid_fetch ($$$;@) {
	my ($self, $tag, $range_csv, @want) = @_;
	my $ibx = $self->{ibx} or return "$tag BAD No mailbox selected\r\n";
	my ($cb, $ops, $partial) = fetch_compile(\@want);
	return "$tag $cb\r\n" unless $ops;

	$range_csv = 'bad' if $range_csv !~ $valid_range;
	my $range_info = range_step($self, \$range_csv);
	return "$tag $range_info\r\n" if !ref($range_info);
	long_response($self, $cb, $tag, [], $range_info, $ops, $partial);
}

sub parse_date ($) { # 02-Oct-1993
	my ($date_text) = @_;
	my ($dd, $mon, $yyyy) = split(/-/, $_[0], 3);
	defined($yyyy) or return;
	my $mm = $MoY{$mon} // return;
	$dd =~ /\A[0123]?[0-9]\z/ or return;
	$yyyy =~ /\A[0-9]{4,}\z/ or return; # Y10K-compatible!
	timegm(0, 0, 0, $dd, $mm, $yyyy);
}

sub uid_search_uid_range { # long_response
	my ($self, $tag, $beg, $end, $sql) = @_;
	my $uids = $self->{ibx}->over->uid_range($$beg, $end, $sql);
	if (@$uids) {
		$$beg = $uids->[-1] + 1;
		$self->msg_more(join(' ', '', @$uids));
	} else {
		$self->write(\"\r\n$tag OK Search done\r\n");
		undef;
	}
}

sub date_search {
	my ($q, $k, $d) = @_;
	my $sql = $q->{sql};

	# Date: header
	if ($k eq 'SENTON') {
		my $end = $d + 86399; # no leap day...
		my $da = strftime('%Y%m%d%H%M%S', gmtime($d));
		my $db = strftime('%Y%m%d%H%M%S', gmtime($end));
		$q->{xap} .= " dt:$da..$db";
		$$sql .= " AND ds >= $d AND ds <= $end" if defined($sql);
	} elsif ($k eq 'SENTBEFORE') {
		$q->{xap} .= ' d:..'.strftime('%Y%m%d', gmtime($d));
		$$sql .= " AND ds <= $d" if defined($sql);
	} elsif ($k eq 'SENTSINCE') {
		$q->{xap} .= ' d:'.strftime('%Y%m%d', gmtime($d)).'..';
		$$sql .= " AND ds >= $d" if defined($sql);

	# INTERNALDATE (Received)
	} elsif ($k eq 'ON') {
		my $end = $d + 86399; # no leap day...
		$q->{xap} .= " ts:$d..$end";
		$$sql .= " AND ts >= $d AND ts <= $end" if defined($sql);
	} elsif ($k eq 'BEFORE') {
		$q->{xap} .= " ts:..$d";
		$$sql .= " AND ts <= $d" if defined($sql);
	} elsif ($k eq 'SINCE') {
		$q->{xap} .= " ts:$d..";
		$$sql .= " AND ts >= $d" if defined($sql);
	} else {
		die "BUG: $k not recognized";
	}
}

# IMAP to Xapian search key mapping
my %I2X = (
	SUBJECT => 's:',
	BODY => 'b:',
	FROM => 'f:',
	TEXT => '', # n.b. does not include all headers
	TO => 't:',
	CC => 'c:',
	# BCC => 'bcc:', # TODO
	# KEYWORD # TODO ? dfpre,dfpost,...
);

sub parse_query {
	my ($self, $rest) = @_;
	if (uc($rest->[0]) eq 'CHARSET') {
		shift @$rest;
		defined(my $c = shift @$rest) or return 'BAD missing charset';
		$c =~ /\A(?:UTF-8|US-ASCII)\z/ or return 'NO [BADCHARSET]';
	}

	my $sql = ''; # date conditions, {sql} deleted if Xapian is needed
	my $q = { xap => '', sql => \$sql };
	while (@$rest) {
		my $k = uc(shift @$rest);
		# default criteria
		next if $k =~ /\A(?:ALL|RECENT|UNSEEN|NEW)\z/;
		next if $k eq 'AND'; # the default, until we support OR
		if ($k =~ $valid_range) { # sequence numbers == UIDs
			push @{$q->{uid}}, $k;
		} elsif ($k eq 'UID') {
			$k = shift(@$rest) // '';
			$k =~ $valid_range or return 'BAD UID range';
			push @{$q->{uid}}, $k;
		} elsif ($k =~ /\A(?:SENT)?(?:SINCE|ON|BEFORE)\z/) {
			my $d = parse_date(shift(@$rest) // '');
			defined $d or return "BAD $k date format";
			date_search($q, $k, $d);
		} elsif ($k =~ /\A(?:SMALLER|LARGER)\z/) {
			delete $q->{sql}; # can't use over.sqlite3
			my $bytes = shift(@$rest) // '';
			$bytes =~ /\A[0-9]+\z/ or return "BAD $k not a number";
			$q->{xap} .= ' bytes:' . ($k eq 'SMALLER' ?
							'..'.(--$bytes) :
							(++$bytes).'..');
		} elsif (defined(my $xk = $I2X{$k})) {
			delete $q->{sql}; # can't use over.sqlite3
			my $arg = shift @$rest;
			defined($arg) or return "BAD $k no arg";

			# Xapian can't handle [*"] in probabilistic terms
			$arg =~ tr/*"//d;
			$q->{xap} .= qq[ $xk:"$arg"];
		} else {
			# TODO: parentheses, OR, NOT ...
			return "BAD $k not supported (yet?)";
		}
	}

	# favor using over.sqlite3 if possible, since Xapian is optional
	if (exists $q->{sql}) {
		delete($q->{xap});
		delete($q->{sql}) if $sql eq '';
	} elsif (!$self->{ibx}->search) {
		return 'BAD Xapian not configured for mailbox';
	}

	if (my $uid = $q->{uid}) {
		((@$uid > 1) || $uid->[0] =~ /,/) and
			return 'BAD multiple ranges not supported, yet';
		($q->{sql} // $q->{xap}) and
			return 'BAD ranges and queries do not mix, yet';
		$q->{uid} = join(',', @$uid); # TODO: multiple ranges
	}
	$q;
}

sub cmd_uid_search ($$$;) {
	my ($self, $tag) = splice(@_, 0, 2);
	my $ibx = $self->{ibx} or return "$tag BAD No mailbox selected\r\n";
	my $q = parse_query($self, \@_);
	return "$tag $q\r\n" if !ref($q);
	my $sql = delete $q->{sql};

	if (!scalar(keys %$q)) {
		$self->msg_more('* SEARCH');
		my $beg = $self->{uid_min} // 1;
		my $end = $ibx->mm->max;
		uid_clamp($self, \$beg, \$end);
		long_response($self, \&uid_search_uid_range,
				$tag, \$beg, $end, $sql);
	} elsif (my $uid = $q->{uid}) {
		if ($uid =~ /\A([0-9]+):([0-9]+|\*)\z/s) {
			my ($beg, $end) = ($1, $2);
			$end = $ibx->mm->max if $end eq '*';
			uid_clamp($self, \$beg, \$end);
			$self->msg_more('* SEARCH');
			long_response($self, \&uid_search_uid_range,
					$tag, \$beg, $end, $sql);
		} elsif ($uid =~ /\A[0-9]+\z/s) {
			$uid = $ibx->over->get_art($uid) ? " $uid" : '';
			"* SEARCH$uid\r\n$tag OK Search done\r\n";
		} else {
			"$tag BAD Error\r\n";
		}
	} else {
		"$tag BAD Error\r\n";
	}
}

sub args_ok ($$) { # duplicated from PublicInbox::NNTP
	my ($cb, $argc) = @_;
	my $tot = prototype $cb;
	my ($nreq, undef) = split(';', $tot);
	$nreq = ($nreq =~ tr/$//) - 1;
	$tot = ($tot =~ tr/$//) - 1;
	($argc <= $tot && $argc >= $nreq);
}

# returns 1 if we can continue, 0 if not due to buffered writes or disconnect
sub process_line ($$) {
	my ($self, $l) = @_;
	my ($tag, $req, @args) = parse_line('[ \t]+', 0, $l);
	pop(@args) if (@args && !defined($args[-1]));
	if (@args && uc($req) eq 'UID') {
		$req .= "_".(shift @args);
	}
	my $res = eval {
		if (my $cmd = $self->can('cmd_'.lc($req // ''))) {
			defined($self->{-idle_tag}) ?
				"$self->{-idle_tag} BAD expected DONE\r\n" :
				$cmd->($self, $tag, @args);
		} elsif (uc($tag // '') eq 'DONE' && !defined($req)) {
			cmd_done($self, $tag);
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
		$self->update_idle_time;

		# control passed to $more may be a GitAsyncCat object
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

	$self->update_idle_time;
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
	my $fd = fileno($self->{sock});
	my $r = eval { process_line($self, $line) };
	my $pending = $self->{wbuf} ? ' pending' : '';
	out($self, "[$fd] %s - %0.6f$pending - $r", $line, now() - $t0);

	return $self->close if $r < 0;
	$self->rbuf_idle($rbuf);
	$self->update_idle_time;

	# maybe there's more pipelined data, or we'll have
	# to register it for socket-readiness notifications
	$self->requeue unless $pending;
}

sub compressed { undef }

sub zflush {} # overridden by IMAPdeflate

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

# for graceful shutdown in PublicInbox::Daemon:
sub busy {
	my ($self, $now) = @_;
	($self->{rbuf} || $self->{wbuf} || $self->not_idle_long($now));
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
*cmd_fetch = \&cmd_uid_fetch;

package PublicInbox::IMAP_preauth;
our @ISA = qw(PublicInbox::IMAP);

sub logged_in { 0 }

1;
