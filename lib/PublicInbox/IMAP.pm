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
#   Most IMAP clients use UIDs (I hope), and we can return a dummy
#   message if a client requests a non-existent MSN.

package PublicInbox::IMAP;
use strict;
use base qw(PublicInbox::DS);
use fields qw(imapd logged_in ibx long_cb -login_tag
	-idle_tag -idle_max);
use PublicInbox::Eml;
use PublicInbox::EmlContentFoo qw(parse_content_disposition);
use PublicInbox::DS qw(now);
use PublicInbox::Syscall qw(EPOLLIN EPOLLONESHOT);
use Text::ParseWords qw(parse_line);
use Errno qw(EAGAIN);
my $Address;
for my $mod (qw(Email::Address::XS Mail::Address)) {
	eval "require $mod" or next;
	$Address = $mod and last;
}
die "neither Email::Address::XS nor Mail::Address loaded: $@" if !$Address;

sub LINE_MAX () { 512 } # does RFC 3501 have a limit like RFC 977?

my %FETCH_NEED_BLOB = ( # for future optimization
	'BODY.PEEK[HEADER]' => 1,
	'BODY.PEEK[TEXT]' => 1,
	'BODY.PEEK[]' => 1,
	'BODY[HEADER]' => 1,
	'BODY[TEXT]' => 1,
	'BODY[]' => 1,
	'RFC822.HEADER' => 1,
	'RFC822.SIZE' => 1, # needs CRLF conversion :<
	'RFC822.TEXT' => 1,
	BODY => 1,
	BODYSTRUCTURE => 1,
	ENVELOPE => 1,
	FLAGS => 0,
	INTERNALDATE => 0,
	RFC822 => 1,
	UID => 0,
);
my %FETCH_ATT = map { $_ => [ $_ ] } keys %FETCH_NEED_BLOB;

# aliases (RFC 3501 section 6.4.5)
$FETCH_ATT{FAST} = [ qw(FLAGS INTERNALDATE RFC822.SIZE) ];
$FETCH_ATT{ALL} = [ @{$FETCH_ATT{FAST}}, 'ENVELOPE' ];
$FETCH_ATT{FULL} = [ @{$FETCH_ATT{ALL}}, 'BODY' ];

for my $att (keys %FETCH_ATT) {
	my %h = map { $_ => 1 } @{$FETCH_ATT{$att}};
	$FETCH_ATT{$att} = \%h;
}

sub greet ($) {
	my ($self) = @_;
	my $capa = capa($self);
	$self->write(\"* OK [$capa] public-inbox-imapd ready\r\n");
}

sub new ($$$) {
	my ($class, $sock, $imapd) = @_;
	my $self = fields::new($class);
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

sub capa ($) {
	my ($self) = @_;

	# dovecot advertises IDLE pre-login; perhaps because some clients
	# depend on it, so we'll do the same
	my $capa = 'CAPABILITY IMAP4rev1 IDLE';
	if ($self->{logged_in}) {
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
	$self->{logged_in} = 1;
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

sub cmd_logout ($$) {
	my ($self, $tag) = @_;
	delete $self->{logged_in};
	$self->write(\"* BYE logging out\r\n$tag OK logout completed\r\n");
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
	'* '.capa($self)."\r\n$tag OK\r\n";
}

sub cmd_noop ($$) { "$_[1] OK NOOP completed\r\n" }

# called by PublicInbox::InboxIdle
sub on_inbox_unlock {
	my ($self, $ibx) = @_;
	my $new = $ibx->mm->max;
	defined(my $old = $self->{-idle_max}) or die 'BUG: -idle_max unset';
	if ($new > $old) {
		$self->{-idle_max} = $new;
		$self->msg_more("* $_ EXISTS\r\n") for (($old + 1)..($new - 1));
		$self->write(\"* $new EXISTS\r\n");
	}
}

sub cmd_idle ($$) {
	my ($self, $tag) = @_;
	# IDLE seems allowed by dovecot w/o a mailbox selected *shrug*
	my $ibx = $self->{ibx} or return "$tag BAD no mailbox selected\r\n";
	$ibx->subscribe_unlock(fileno($self->{sock}), $self);
	$self->{imapd}->idler_start;
	$self->{-idle_tag} = $tag;
	$self->{-idle_max} = $ibx->mm->max // 0;
	"+ idling\r\n"
}

sub cmd_done ($$) {
	my ($self, $tag) = @_; # $tag is "DONE" (case-insensitive)
	defined(my $idle_tag = delete $self->{-idle_tag}) or
		return "$tag BAD not idle\r\n";
	my $ibx = $self->{ibx} or do {
		warn "BUG: idle_tag set w/o inbox";
		return "$tag BAD internal bug\r\n";
	};
	$ibx->unsubscribe_unlock(fileno($self->{sock}));
	"$idle_tag OK Idle completed\r\n";
}

sub cmd_examine ($$$) {
	my ($self, $tag, $mailbox) = @_;
	my $ibx = $self->{imapd}->{groups}->{$mailbox} or
		return "$tag NO Mailbox doesn't exist: $mailbox\r\n";
	my $mm = $ibx->mm;
	my $max = $mm->max // 0;
	# RFC 3501 2.3.1.1 -  "A good UIDVALIDITY value to use in
	# this case is a 32-bit representation of the creation
	# date/time of the mailbox"
	my $uidvalidity = $mm->created_at or return "$tag BAD UIDVALIDITY\r\n";
	my $uidnext = $max + 1;

	# XXX: do we need this? RFC 5162/7162
	my $ret = $self->{ibx} ? "* OK [CLOSED] previous closed\r\n" : '';
	$self->{ibx} = $ibx;
	$ret .= <<EOF;
* $max EXISTS\r
* $max RECENT\r
* FLAGS (\\Seen)\r
* OK [PERMANENTFLAGS ()] Read-only mailbox\r
EOF
	$ret .= "* OK [UNSEEN $max]\r\n" if $max;
	$ret .= "* OK [UIDNEXT $uidnext]\r\n" if defined $uidnext;
	$ret .= "* OK [UIDVALIDITY $uidvalidity]\r\n" if defined $uidvalidity;
	$ret .= "$tag OK [READ-ONLY] EXAMINE/SELECT complete\r\n";
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

sub uid_fetch_cb { # called by git->cat_async
	my ($bref, $oid, $type, $size, $fetch_m_arg) = @_;
	my ($self, undef, $ibx, undef, undef, $msgs, $want) = @$fetch_m_arg;
	my $smsg = shift @$msgs or die 'BUG: no smsg';
	$smsg->{blob} eq $oid or die "BUG: $smsg->{blob} != $oid";
	$$bref =~ s/(?<!\r)\n/\r\n/sg; # make strict clients happy

	# fixup old bug from import (pre-a0c07cba0e5d8b6a)
	$$bref =~ s/\A[\r\n]*From [^\r\n]*\r\n//s;

	$self->msg_more("* $smsg->{num} FETCH (UID $smsg->{num}");

	$want->{'RFC822.SIZE'} and
		$self->msg_more(' RFC822.SIZE '.length($$bref));
	$want->{INTERNALDATE} and
		$self->msg_more(' INTERNALDATE "'.$smsg->internaldate.'"');
	$want->{FLAGS} and $self->msg_more(' FLAGS ()');
	for ('RFC822', 'BODY[]', 'BODY.PEEK[]') {
		next unless $want->{$_};
		$self->msg_more(" $_ {".length($$bref)."}\r\n");
		$self->msg_more($$bref);
	}

	my $eml = PublicInbox::Eml->new($bref);

	$want->{ENVELOPE} and
		$self->msg_more(' ENVELOPE '.eml_envelope($eml));

	for my $f ('RFC822.HEADER', 'BODY[HEADER]', 'BODY.PEEK[HEADER]') {
		next unless $want->{$f};
		$self->msg_more(" $f {".length(${$eml->{hdr}})."}\r\n");
		$self->msg_more(${$eml->{hdr}});
	}
	for my $f ('RFC822.TEXT', 'BODY[TEXT]') {
		next unless $want->{$f};
		$self->msg_more(" $f {".length($$bref)."}\r\n");
		$self->msg_more($$bref);
	}
	$want->{BODYSTRUCTURE} and
		$self->msg_more(' BODYSTRUCTURE '.fetch_body($eml, 1));
	$want->{BODY} and
		$self->msg_more(' BODY '.fetch_body($eml));

	$self->msg_more(")\r\n");
}

sub uid_fetch_m { # long_response
	my ($self, $tag, $ibx, $beg, $end, $msgs, $want) = @_;
	if (!@$msgs) { # refill
		@$msgs = @{$ibx->over->query_xover($$beg, $end)};
		if (!@$msgs) {
			$self->write(\"$tag OK Fetch done\r\n");
			return;
		}
		$$beg = $msgs->[-1]->{num} + 1;
	}
	my $git = $ibx->git;
	$git->cat_async_begin; # TODO: actually make async
	$git->cat_async($msgs->[0]->{blob}, \&uid_fetch_cb, \@_);
	$git->cat_async_wait;
	1;
}

sub cmd_status ($$$;@) {
	my ($self, $tag, $mailbox, @items) = @_;
	my $ibx = $self->{imapd}->{groups}->{$mailbox} or
		return "$tag NO Mailbox doesn't exist: $mailbox\r\n";
	return "$tag BAD no items\r\n" if !scalar(@items);
	($items[0] !~ s/\A\(//s || $items[-1] !~ s/\)\z//s) and
		return "$tag BAD invalid args\r\n";

	my $mm = $ibx->mm;
	my ($max, @it);
	for my $it (@items) {
		$it = uc($it);
		push @it, $it;
		if ($it =~ /\A(?:MESSAGES|UNSEEN|RECENT)\z/) {
			push(@it, ($max //= $mm->max // 0));
		} elsif ($it eq 'UIDNEXT') {
			push(@it, ($max //= $mm->max // 0) + 1);
		} elsif ($it eq 'UIDVALIDITY') {
			push(@it, $mm->created_at //
				return("$tag BAD UIDVALIDITY\r\n"));
		} else {
			return "$tag BAD invalid item\r\n";
		}
	}
	return "$tag BAD no items\r\n" if !@it;
	"* STATUS $mailbox (".join(' ', @it).")\r\n" .
	"$tag OK Status complete\r\n";
}

my %patmap = ('*' => '.*', '%' => '[^\.]*');
sub cmd_list ($$$$) {
	my ($self, $tag, $refname, $wildcard) = @_;
	my $l = $self->{imapd}->{inboxlist};
	if ($refname eq '' && $wildcard eq '') {
		# request for hierarchy delimiter
		$l = [ qq[* LIST (\\Noselect) "." ""\r\n] ];
	} elsif ($refname ne '' || $wildcard ne '*') {
		$wildcard =~ s!([^a-z0-9_])!$patmap{$1} // "\Q$1"!eig;
		$l = [ grep(/ \Q$refname\E$wildcard\r\n\z/s, @$l) ];
	}
	\(join('', @$l, "$tag OK List complete\r\n"));
}

sub cmd_uid_fetch ($$$;@) {
	my ($self, $tag, $range, @want) = @_;
	my $ibx = $self->{ibx} or return "$tag BAD No mailbox selected\r\n";
	if ($want[0] =~ s/\A\(//s) {
		$want[-1] =~ s/\)\z//s or return "$tag BAD no rparen\r\n";
	}
	my %want = map {;
		my $x = $FETCH_ATT{uc($_)} or return "$tag BAD param: $_\r\n";
		%$x;
	} @want;
	my ($beg, $end);
	my $msgs = [];
	if ($range =~ /\A([0-9]+):([0-9]+)\z/s) {
		($beg, $end) = ($1, $2);
	} elsif ($range =~ /\A([0-9]+):\*\z/s) {
		($beg, $end) =  ($1, $ibx->mm->max // 0);
	} elsif ($range =~ /\A[0-9]+\z/) {
		my $smsg = $ibx->over->get_art($range) or return "$tag OK\r\n";
		push @$msgs, $smsg;
		($beg, $end) = ($range, 0);
	} else {
		return "$tag BAD\r\n";
	}
	long_response($self, \&uid_fetch_m, $tag, $ibx,
				\$beg, $end, $msgs, \%want);
}

sub uid_search_all { # long_response
	my ($self, $tag, $ibx, $num) = @_;
	my $uids = $ibx->mm->ids_after($num);
	if (scalar(@$uids)) {
		$self->msg_more(join(' ', '', @$uids));
	} else {
		$self->write(\"\r\n$tag OK\r\n");
		undef;
	}
}

sub uid_search_uid_range { # long_response
	my ($self, $tag, $ibx, $beg, $end) = @_;
	my $uids = $ibx->mm->msg_range($beg, $end, 'num');
	if (@$uids) {
		$self->msg_more(join('', map { " $_->[0]" } @$uids));
	} else {
		$self->write(\"\r\n$tag OK\r\n");
		undef;
	}
}

sub cmd_uid_search ($$$;) {
	my ($self, $tag, $arg, @rest) = @_;
	my $ibx = $self->{ibx} or return "$tag BAD No mailbox selected\r\n";
	$arg = uc($arg);
	if ($arg eq 'ALL' && !@rest) {
		$self->msg_more('* SEARCH');
		my $num = 0;
		long_response($self, \&uid_search_all, $tag, $ibx, \$num);
	} elsif ($arg eq 'UID' && scalar(@rest) == 1) {
		if ($rest[0] =~ /\A([0-9]+):([0-9]+|\*)\z/s) {
			my ($beg, $end) = ($1, $2);
			$end = $ibx->mm->max if $end eq '*';
			$self->msg_more('* SEARCH');
			long_response($self, \&uid_search_uid_range,
					$tag, $ibx, \$beg, $end);
		} elsif ($rest[0] =~ /\A[0-9]+\z/s) {
			my $uid = $rest[0];
			$uid = $ibx->over->get_art($uid) ? " $uid" : '';
			"* SEARCH$uid\r\n$tag OK\r\n";
		} else {
			"$tag BAD\r\n";
		}
	} else {
		"$tag BAD\r\n";
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
				"$tag BAD Error in IMAP command $req: ".
				"Unknown command\r\n";
		}
	};
	my $err = $@;
	if ($err && $self->{sock}) {
		$l =~ s/\r?\n//s;
		err($self, 'error from: %s (%s)', $l, $err);
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

		# COMPRESS users all share the same DEFLATE context.
		# Flush it here to ensure clients don't see
		# each other's data
		$self->zflush;

		# no recursion, schedule another call ASAP, but only after
		# all pending writes are done.  autovivify wbuf:
		my $new_size = push(@{$self->{wbuf}}, \&long_step);

		# wbuf may be populated by $cb, no need to rearm if so:
		$self->requeue if $new_size == 1;
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

	return unless $self->flush_write && $self->{sock};

	$self->update_idle_time;
	# only read more requests if we've drained the write buffer,
	# otherwise we can be buffering infinitely w/o backpressure

	my $rbuf = $self->{rbuf} // (\(my $x = ''));
	my $r = 1;

	if (index($$rbuf, "\n") < 0) {
		my $off = length($$rbuf);
		$r = $self->do_read($rbuf, LINE_MAX, $off) or return;
	}
	while ($r > 0 && $$rbuf =~ s/\A[ \t]*([^\n]*?)\r?\n//) {
		my $line = $1;
		return $self->close if $line =~ /[[:cntrl:]]/s;
		my $t0 = now();
		my $fd = fileno($self->{sock});
		$r = eval { process_line($self, $line) };
		my $pending = $self->{wbuf} ? ' pending' : '';
		out($self, "[$fd] %s - %0.6f$pending", $line, now() - $t0);
	}

	return $self->close if $r < 0;
	my $len = length($$rbuf);
	return $self->close if ($len >= LINE_MAX);
	$self->rbuf_idle($rbuf);
	$self->update_idle_time;

	# maybe there's more pipelined data, or we'll have
	# to register it for socket-readiness notifications
	$self->requeue unless $self->{wbuf};
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
		if (my $sock = $self->{sock}) {;
			$ibx->unsubscribe_unlock(fileno($sock));
		}
	}
	$self->SUPER::close; # PublicInbox::DS::close
}

# we're read-only, so SELECT and EXAMINE do the same thing
no warnings 'once';
*cmd_select = \&cmd_examine;

1;
