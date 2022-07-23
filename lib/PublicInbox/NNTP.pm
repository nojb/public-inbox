# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Each instance of this represents a NNTP client socket
# fields:
# nntpd: PublicInbox::NNTPD ref
# article: per-session current article number
# ibx: PublicInbox::Inbox ref
# long_cb: long_response private data
package PublicInbox::NNTP;
use strict;
use v5.10.1;
use parent qw(PublicInbox::DS);
use PublicInbox::MID qw(mid_escape $MID_EXTRACT);
use PublicInbox::Eml;
use POSIX qw(strftime);
use PublicInbox::DS qw(now);
use Digest::SHA qw(sha1_hex);
use Time::Local qw(timegm timelocal);
use PublicInbox::GitAsyncCat;
use PublicInbox::Address;

use constant {
	LINE_MAX => 512, # RFC 977 section 2.3
	r501 => '501 command syntax error',
	r502 => '502 Command unavailable',
	r221 => "221 Header follows\r\n",
	r224 => '224 Overview information follows (multi-line)',
	r225 =>	"225 Headers follow (multi-line)\r\n",
	r430 => '430 No article with that message-id',
};
use PublicInbox::Syscall qw(EPOLLIN EPOLLONESHOT);
use Errno qw(EAGAIN);
my $ONE_MSGID = qr/\A$MID_EXTRACT\z/;
my @OVERVIEW = qw(Subject From Date Message-ID References);
my $OVERVIEW_FMT = join(":\r\n", @OVERVIEW, qw(Bytes Lines), '') .
		"Xref:full\r\n.";
my $LIST_HEADERS = join("\r\n", @OVERVIEW,
			qw(:bytes :lines Xref To Cc)) . "\r\n.";
my $CAPABILITIES = <<"";
101 Capability list:\r
VERSION 2\r
READER\r
NEWNEWS\r
LIST ACTIVE ACTIVE.TIMES NEWSGROUPS OVERVIEW.FMT\r
HDR\r
OVER\r
COMPRESS DEFLATE\r

sub greet ($) { $_[0]->write($_[0]->{nntpd}->{greet}) };

sub new ($$$) {
	my ($class, $sock, $nntpd) = @_;
	my $self = bless { nntpd => $nntpd }, $class;
	my $ev = EPOLLIN;
	my $wbuf;
	if ($sock->can('accept_SSL') && !$sock->accept_SSL) {
		return CORE::close($sock) if $! != EAGAIN;
		$ev = PublicInbox::TLS::epollbit() or return CORE::close($sock);
		$wbuf = [ \&PublicInbox::DS::accept_tls_step, \&greet ];
	}
	$self->SUPER::new($sock, $ev | EPOLLONESHOT);
	if ($wbuf) {
		$self->{wbuf} = $wbuf;
	} else {
		greet($self);
	}
	$self;
}

sub args_ok ($$) {
	my ($cb, $argc) = @_;
	my $tot = prototype $cb;
	my ($nreq, undef) = split(/;/, $tot);
	$nreq = ($nreq =~ tr/$//) - 1;
	$tot = ($tot =~ tr/$//) - 1;
	($argc <= $tot && $argc >= $nreq);
}

# returns 1 if we can continue, 0 if not due to buffered writes or disconnect
sub process_line ($$) {
	my ($self, $l) = @_;
	my ($req, @args) = split(/[ \t]+/, $l);
	return 1 unless defined($req); # skip blank line
	$req = $self->can('cmd_'.lc($req)) //
		return $self->write(\"500 command not recognized\r\n");
	return res($self, r501) unless args_ok($req, scalar @args);

	my $res = eval { $req->($self, @args) };
	my $err = $@;
	if ($err && $self->{sock}) {
		local $/ = "\n";
		chomp($l);
		err($self, 'error from: %s (%s)', $l, $err);
		$res = '503 program fault - command not performed';
	}
	defined($res) ? res($self, $res) : 0;
}

# The keyword argument is not used (rfc3977 5.2.2)
sub cmd_capabilities ($;$) {
	my ($self, undef) = @_;
	my $res = $CAPABILITIES;
	if (!$self->{sock}->can('accept_SSL') &&
			$self->{nntpd}->{accept_tls}) {
		$res .= "STARTTLS\r\n";
	}
	$res .= '.';
}

sub cmd_mode ($$) {
	my ($self, $arg) = @_;
	uc($arg) eq 'READER' ? '201 Posting prohibited' : r501;
}

sub cmd_slave ($) { '202 slave status noted' }

sub cmd_xgtitle ($;$) {
	my ($self, $wildmat) = @_;
	more($self, '282 list of groups and descriptions follows');
	list_newsgroups($self, $wildmat);
}

sub list_overview_fmt ($) { $OVERVIEW_FMT }

sub list_headers ($;$) { $LIST_HEADERS }

sub list_active_i { # "LIST ACTIVE" and also just "LIST" (no args)
	my ($self, $groupnames) = @_;
	my @window = splice(@$groupnames, 0, 100) or return 0;
	my $ibx;
	my $groups = $self->{nntpd}->{pi_cfg}->{-by_newsgroup};
	for my $ngname (@window) {
		$ibx = $groups->{$ngname} and group_line($self, $ibx);
	}
	scalar(@$groupnames); # continue if there's more
}

sub list_active ($;$) { # called by cmd_list
	my ($self, $wildmat) = @_;
	wildmat2re($wildmat);
	long_response($self, \&list_active_i, [
		grep(/$wildmat/, @{$self->{nntpd}->{groupnames}}) ]);
}

sub list_active_times_i {
	my ($self, $groupnames) = @_;
	my @window = splice(@$groupnames, 0, 100) or return 0;
	my $groups = $self->{nntpd}->{pi_cfg}->{-by_newsgroup};
	for my $ngname (@window) {
		my $ibx = $groups->{$ngname} or next;
		my $c = eval { $ibx->uidvalidity } // time;
		more($self, "$ngname $c <$ibx->{-primary_address}>");
	}
	scalar(@$groupnames); # continue if there's more
}

sub list_active_times ($;$) { # called by cmd_list
	my ($self, $wildmat) = @_;
	wildmat2re($wildmat);
	long_response($self, \&list_active_times_i, [
		grep(/$wildmat/, @{$self->{nntpd}->{groupnames}}) ]);
}

sub list_newsgroups_i {
	my ($self, $groupnames) = @_;
	my @window = splice(@$groupnames, 0, 100) or return 0;
	my $groups = $self->{nntpd}->{pi_cfg}->{-by_newsgroup};
	my $ibx;
	for my $ngname (@window) {
		$ibx = $groups->{$ngname} and
			more($self, "$ngname ".$ibx->description);
	}
	scalar(@$groupnames); # continue if there's more
}

sub list_newsgroups ($;$) { # called by cmd_list
	my ($self, $wildmat) = @_;
	wildmat2re($wildmat);
	long_response($self, \&list_newsgroups_i, [
		grep(/$wildmat/, @{$self->{nntpd}->{groupnames}}) ]);
}

# LIST SUBSCRIPTIONS, DISTRIB.PATS are not supported
sub cmd_list ($;$$) {
	my ($self, @args) = @_;
	if (scalar @args) {
		my $arg = shift @args;
		$arg =~ tr/A-Z./a-z_/;
		my $ret = $arg eq 'active';
		$arg = "list_$arg";
		$arg = $self->can($arg);
		return r501 unless $arg && args_ok($arg, scalar @args);
		more($self, '215 information follows');
		$arg->($self, @args);
	} else {
		more($self, '215 list of newsgroups follows');
		long_response($self, \&list_active_i, [ # copy array
			@{$self->{nntpd}->{groupnames}} ]);
	}
}

sub listgroup_range_i {
	my ($self, $beg, $end) = @_;
	my $r = $self->{ibx}->mm(1)->msg_range($beg, $end, 'num');
	scalar(@$r) or return;
	$self->msg_more(join('', map { "$_->[0]\r\n" } @$r));
	1;
}

sub listgroup_all_i {
	my ($self, $num) = @_;
	my $ary = $self->{ibx}->over(1)->ids_after($num);
	scalar(@$ary) or return;
	more($self, join("\r\n", @$ary));
	1;
}

sub cmd_listgroup ($;$$) {
	my ($self, $group, $range) = @_;
	if (defined $group) {
		my $res = cmd_group($self, $group);
		return $res if ($res !~ /\A211 /);
		more($self, $res);
	}
	$self->{ibx} or return '412 no newsgroup selected';
	if (defined $range) {
		my $r = get_range($self, $range);
		return $r unless ref $r;
		long_response($self, \&listgroup_range_i, @$r);
	} else { # grab every article number
		long_response($self, \&listgroup_all_i, \(my $num = 0));
	}
}

sub parse_time ($$;$) {
	my ($date, $time, $gmt) = @_;
	my ($hh, $mm, $ss) = unpack('A2A2A2', $time);
	if (defined $gmt) {
		$gmt =~ /\A(?:UTC|GMT)\z/i or die "GM invalid: $gmt";
		$gmt = 1;
	}
	my ($YYYY, $MM, $DD);
	if (length($date) == 8) { # RFC 3977 allows YYYYMMDD
		($YYYY, $MM, $DD) = unpack('A4A2A2', $date);
	} else { # legacy clients send YYMMDD
		my $YY;
		($YY, $MM, $DD) = unpack('A2A2A2', $date);
		my @now = $gmt ? gmtime : localtime;
		my $cur_year = $now[5] + 1900;
		my $cur_cent = int($cur_year / 100) * 100;
		$YYYY = (($YY + $cur_cent) > $cur_year) ?
			($YY + 1900) : ($YY + $cur_cent);
	}
	if ($gmt) {
		timegm($ss, $mm, $hh, $DD, $MM - 1, $YYYY);
	} else {
		timelocal($ss, $mm, $hh, $DD, $MM - 1, $YYYY);
	}
}

sub group_line ($$) {
	my ($self, $ibx) = @_;
	my ($min, $max) = $ibx->mm(1)->minmax;
	more($self, "$ibx->{newsgroup} $max $min n");
}

sub newgroups_i {
	my ($self, $ts, $i, $groupnames) = @_;
	my $end = $$i + 100;
	my $groups = $self->{nntpd}->{pi_cfg}->{-by_newsgroup};
	while ($$i < $end) {
		my $ngname = $groupnames->[$$i++] // return;
		my $ibx = $groups->{$ngname} or next; # expired on reload
		next unless (eval { $ibx->uidvalidity } // 0) > $ts;
		group_line($self, $ibx);
	}
	1;
}

sub cmd_newgroups ($$$;$$) {
	my ($self, $date, $time, $gmt, $dists) = @_;
	my $ts = eval { parse_time($date, $time, $gmt) };
	return r501 if $@;

	# TODO dists
	more($self, '231 list of new newsgroups follows');
	long_response($self, \&newgroups_i, $ts, \(my $i = 0),
				$self->{nntpd}->{groupnames});
}

sub wildmat2re (;$) {
	return $_[0] = qr/.*/ if (!defined $_[0] || $_[0] eq '*');
	my %keep;
	my $salt = rand;
	my $tmp = $_[0];

	$tmp =~ s#(?<!\\)\[(.+)(?<!\\)\]#
		my $orig = $1;
		my $key = sha1_hex($orig . $salt);
		$orig =~ s/([^\w\-])+/\Q$1/g;
		$keep{$key} = $orig;
		$key
		#gex;
	my %map = ('*' => '.*', '?' => '.' );
	$tmp =~ s#(?<!\\)([^\w\\])#$map{$1} || "\Q$1"#ge;
	if (scalar %keep) {
		$tmp =~ s#([a-f0-9]{40})#
			my $orig = $keep{$1};
			defined $orig ? $orig : $1;
			#ge;
	}
	$_[0] = qr/\A$tmp\z/;
}

sub ngpat2re (;$) {
	return $_[0] = qr/\A\z/ unless defined $_[0];
	my %map = ('*' => '.*', ',' => '|');
	$_[0] =~ s!(.)!$map{$1} || "\Q$1"!ge;
	$_[0] = qr/\A(?:$_[0])\z/;
}

sub newnews_i {
	my ($self, $names, $ts, $prev) = @_;
	my $ngname = $names->[0];
	if (my $ibx = $self->{nntpd}->{pi_cfg}->{-by_newsgroup}->{$ngname}) {
		if (my $over = $ibx->over) {
			my $msgs = $over->query_ts($ts, $$prev);
			if (scalar @$msgs) {
				$self->msg_more(join('', map {
							"<$_->{mid}>\r\n";
						} @$msgs));
				$$prev = $msgs->[-1]->{num};
				return 1; # continue on current group
			}
		}
	}
	shift @$names;
	if (@$names) { # continue onto next newsgroup
		$$prev = 0;
		1;
	} else { # all done, break out of the long_response
		undef;
	}
}

sub cmd_newnews ($$$$;$$) {
	my ($self, $newsgroups, $date, $time, $gmt, $dists) = @_;
	my $ts = eval { parse_time($date, $time, $gmt) };
	return r501 if $@;
	more($self, '230 list of new articles by message-id follows');
	my ($keep, $skip) = split(/!/, $newsgroups, 2);
	ngpat2re($keep);
	ngpat2re($skip);
	my @names = grep(!/$skip/, grep(/$keep/,
				@{$self->{nntpd}->{groupnames}}));
	return '.' unless scalar(@names);
	my $prev = 0;
	long_response($self, \&newnews_i, \@names, $ts, \$prev);
}

sub cmd_group ($$) {
	my ($self, $group) = @_;
	my $nntpd = $self->{nntpd};
	my $ibx = $nntpd->{pi_cfg}->{-by_newsgroup}->{$group} or
		return '411 no such news group';
	$nntpd->idler_start;

	$self->{ibx} = $ibx;
	my ($min, $max) = $ibx->mm(1)->minmax;
	$self->{article} = $min;
	my $est_size = $max - $min;
	"211 $est_size $min $max $group";
}

sub article_adj ($$) {
	my ($self, $off) = @_;
	my $ibx = $self->{ibx} or return '412 no newsgroup selected';

	my $n = $self->{article};
	defined $n or return '420 no current article has been selected';

	$n += $off;
	my $mid = $ibx->mm(1)->mid_for($n) // do {
		$n = $off > 0 ? 'next' : 'previous';
		return "421 no $n article in this group";
	};
	$self->{article} = $n;
	"223 $n <$mid> article retrieved - request text separately";
}

sub cmd_next ($) { article_adj($_[0], 1) }
sub cmd_last ($) { article_adj($_[0], -1) }

# We want to encourage using email and CC-ing everybody involved to avoid
# the single-point-of-failure a single server provides.
sub cmd_post ($) {
	my ($self) = @_;
	my $ibx = $self->{ibx};
	$ibx ? "440 mailto:$ibx->{-primary_address} to post"
		: '440 posting not allowed'
}

sub cmd_quit ($) {
	my ($self) = @_;
	$self->write(\"205 closing connection - goodbye!\r\n");
	$self->shutdn;
	undef;
}

sub xref_by_tc ($$$) {
	my ($xref, $pi_cfg, $smsg) = @_;
	my $by_addr = $pi_cfg->{-by_addr};
	my $mid = $smsg->{mid};
	for my $f (qw(to cc)) {
		my @ibxs = map {
			$by_addr->{lc($_)} // ()
		} (PublicInbox::Address::emails($smsg->{$f} // ''));
		for my $ibx (@ibxs) {
			$xref->{$ibx->{newsgroup}} //=
						$ibx->mm(1)->num_for($mid);
		}
	}
}

sub xref ($$$) {
	my ($self, $cur_ibx, $smsg) = @_;
	my $nntpd = $self->{nntpd};
	my $cur_ng = $cur_ibx->{newsgroup};
	my $xref;
	if (my $ALL = $nntpd->{pi_cfg}->ALL) {
		$xref = $ALL->nntp_xref_for($cur_ibx, $smsg);
		xref_by_tc($xref, $nntpd->{pi_cfg}, $smsg);
	} else { # slow path
		$xref = { $cur_ng => $smsg->{num} };
		my $mid = $smsg->{mid};
		for my $ibx (values %{$nntpd->{pi_cfg}->{-by_newsgroup}}) {
			$xref->{$ibx->{newsgroup}} //=
						 $ibx->mm(1)->num_for($mid);
		}
	}
	my $ret = "$nntpd->{servername} $cur_ng:".delete($xref->{$cur_ng});
	for my $ng (sort keys %$xref) {
		my $num = $xref->{$ng} // next;
		$ret .= " $ng:$num";
	}
	$ret;
}

sub set_nntp_headers ($$) {
	my ($hdr, $smsg) = @_;
	my ($mid) = $smsg->{mid};

	# leafnode (and maybe other NNTP clients) have trouble dealing
	# with v2 messages which have multiple Message-IDs (either due
	# to our own content-based dedupe or buggy git-send-email versions).
	my @mids = $hdr->header_raw('Message-ID');
	if (scalar(@mids) > 1) {
		my $mid0 = "<$mid>";
		$hdr->header_set('Message-ID', $mid0);
		my @alt = $hdr->header_raw('X-Alt-Message-ID');
		my %seen = map { $_ => 1 } (@alt, $mid0);
		push(@alt, grep { !$seen{$_}++ } @mids);
		$hdr->header_set('X-Alt-Message-ID', @alt);
	}

	# clobber some existing headers
	my $ibx = $smsg->{-ibx};
	my $xref = xref($smsg->{nntp}, $ibx, $smsg);
	$hdr->header_set('Xref', $xref);

	# RFC 5536 3.1.4
	my ($server_name, $newsgroups) = split(/ /, $xref, 2);
	$newsgroups =~ s/:[0-9]+\b//g; # drop NNTP article numbers
	$newsgroups =~ tr/ /,/;
	$hdr->header_set('Newsgroups', $newsgroups);

	# *something* here is required for leafnode, try to follow
	# RFC 5536 3.1.5...
	$hdr->header_set('Path', $server_name . '!not-for-mail');
}

sub art_lookup ($$$) {
	my ($self, $art, $code) = @_;
	my ($ibx, $n);
	my $err;
	if (defined $art) {
		if ($art =~ /\A[0-9]+\z/) {
			$err = '423 no such article number in this group';
			$n = int($art);
			goto find_ibx;
		} elsif ($art =~ $ONE_MSGID) {
			($ibx, $n) = mid_lookup($self, $1);
			goto found if $ibx;
			return r430;
		} else {
			return r501;
		}
	} else {
		$err = '420 no current article has been selected';
		$n = $self->{article} // return $err;
find_ibx:
		$ibx = $self->{ibx} or
				return '412 no newsgroup has been selected';
	}
found:
	my $smsg = $ibx->over(1)->get_art($n) or return $err;
	$smsg->{-ibx} = $ibx;
	if ($code == 223) { # STAT
		set_art($self, $n);
		"223 $n <$smsg->{mid}> article retrieved - " .
			"request text separately";
	} else { # HEAD | BODY | ARTICLE
		$smsg->{nntp} = $self;
		$smsg->{nntp_code} = $code;
		set_art($self, $art);
		# this dereferences to `undef'
		${ibx_async_cat($ibx, $smsg->{blob}, \&blob_cb, $smsg)};
	}
}

sub msg_body_write ($$) {
	my ($self, $msg) = @_;

	# these can momentarily double the memory consumption :<
	$$msg =~ s/^\./../smg;
	$$msg =~ s/(?<!\r)\n/\r\n/sg; # Alpine barfs without this
	$$msg .= "\r\n" unless $$msg =~ /\r\n\z/s;
	$self->msg_more($$msg);
}

sub set_art {
	my ($self, $art) = @_;
	$self->{article} = $art if defined $art && $art =~ /\A[0-9]+\z/;
}

sub msg_hdr_write ($$) {
	my ($eml, $smsg) = @_;
	set_nntp_headers($eml, $smsg);

	my $hdr = $eml->{hdr} // \(my $x = '');
	# fixup old bug from import (pre-a0c07cba0e5d8b6a)
	$$hdr =~ s/\A[\r\n]*From [^\r\n]*\r?\n//s;
	$$hdr =~ s/(?<!\r)\n/\r\n/sg; # Alpine barfs without this

	# for leafnode compatibility, we need to ensure Message-ID headers
	# are only a single line.
	$$hdr =~ s/^(Message-ID:)[ \t]*\r\n[ \t]+([^\r]+)\r\n/$1 $2\r\n/igsm;
	$smsg->{nntp}->msg_more($$hdr);
}

sub blob_cb { # called by git->cat_async via ibx_async_cat
	my ($bref, $oid, $type, $size, $smsg) = @_;
	my $self = $smsg->{nntp};
	my $code = $smsg->{nntp_code};
	if (!defined($oid)) {
		# it's possible to have TOCTOU if an admin runs
		# public-inbox-(edit|purge), just move onto the next message
		warn "E: $smsg->{blob} missing in $smsg->{-ibx}->{inboxdir}\n";
		return $self->requeue;
	} elsif ($smsg->{blob} ne $oid) {
		$self->close;
		die "BUG: $smsg->{blob} != $oid";
	}
	my $r = "$code $smsg->{num} <$smsg->{mid}> article retrieved - ";
	my $eml = PublicInbox::Eml->new($bref);
	if ($code == 220) {
		more($self, $r .= 'head and body follow');
		msg_hdr_write($eml, $smsg);
		$self->msg_more("\r\n");
		msg_body_write($self, $bref);
	} elsif ($code == 221) {
		more($self, $r .= 'head follows');
		msg_hdr_write($eml, $smsg);
	} elsif ($code == 222) {
		more($self, $r .= 'body follows');
		msg_body_write($self, $bref);
	} else {
		$self->close;
		die "BUG: bad code: $r";
	}
	$self->write(\".\r\n"); # flushes (includes ->zflush)
	$self->requeue;
}

sub cmd_article ($;$) {
	my ($self, $art) = @_;
	art_lookup($self, $art, 220);
}

sub cmd_head ($;$) {
	my ($self, $art) = @_;
	art_lookup($self, $art, 221);
}

sub cmd_body ($;$) {
	my ($self, $art) = @_;
	art_lookup($self, $art, 222);
}

sub cmd_stat ($;$) {
	my ($self, $art) = @_;
	art_lookup($self, $art, 223); # art may be msgid
}

sub cmd_ihave ($) { '435 article not wanted - do not send it' }

sub cmd_date ($) { '111 '.strftime('%Y%m%d%H%M%S', gmtime(time)) }

sub cmd_help ($) {
	my ($self) = @_;
	more($self, '100 help text follows');
	'.'
}

sub get_range ($$) {
	my ($self, $range) = @_;
	my $ibx = $self->{ibx} or return '412 no news group has been selected';
	defined $range or return '420 No article(s) selected';
	my ($beg, $end);
	my ($min, $max) = $ibx->mm(1)->minmax;
	if ($range =~ /\A([0-9]+)\z/) {
		$beg = $end = $1;
	} elsif ($range =~ /\A([0-9]+)-\z/) {
		($beg, $end) = ($1, $max);
	} elsif ($range =~ /\A([0-9]+)-([0-9]+)\z/) {
		($beg, $end) = ($1, $2);
	} else {
		return r501;
	}
	$beg = $min if ($beg < $min);
	$end = $max if ($end > $max);
	return '420 No article(s) selected' if ($beg > $end);
	[ \$beg, $end ];
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
		$self->write(\".\r\n");
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

sub hdr_msgid_range_i {
	my ($self, $beg, $end) = @_;
	my $r = $self->{ibx}->mm(1)->msg_range($beg, $end);
	@$r or return;
	$self->msg_more(join('', map { "$_->[0] <$_->[1]>\r\n" } @$r));
	1;
}

sub hdr_message_id ($$$) { # optimize XHDR Message-ID [range] for slrnpull.
	my ($self, $xhdr, $range) = @_;

	if (defined $range && $range =~ $ONE_MSGID) {
		my ($ibx, $n) = mid_lookup($self, $1);
		return r430 unless $n;
		hdr_mid_response($self, $xhdr, $ibx, $n, $range, $range);
	} else { # numeric range
		$range = $self->{article} unless defined $range;
		my $r = get_range($self, $range);
		return $r unless ref $r;
		$self->msg_more($xhdr ? r221 : r225);
		long_response($self, \&hdr_msgid_range_i, @$r);
	}
}

sub mid_lookup ($$) {
	my ($self, $mid) = @_;
	my $cur_ibx = $self->{ibx};
	if ($cur_ibx) {
		my $n = $cur_ibx->mm(1)->num_for($mid);
		return ($cur_ibx, $n) if defined $n;
	}
	my $pi_cfg = $self->{nntpd}->{pi_cfg};
	if (my $ALL = $pi_cfg->ALL) {
		my ($id, $prev);
		while (my $smsg = $ALL->over->next_by_mid($mid, \$id, \$prev)) {
			my $xr3 = $ALL->over->get_xref3($smsg->{num});
			if (my @x = grep(/:$smsg->{blob}\z/, @$xr3)) {
				my ($ngname, $xnum) = split(/:/, $x[0]);
				my $ibx = $pi_cfg->{-by_newsgroup}->{$ngname};
				return ($ibx, $xnum) if $ibx;
				# fall through to trying all xref3s
			} else {
				warn <<EOF;
W: xref3 missing for <$mid> ($smsg->{blob}) in $ALL->{topdir}, -extindex bug?
EOF
			}
			# try all xref3s
			for my $x (@$xr3) {
				my ($ngname, $xnum) = split(/:/, $x);
				my $ibx = $pi_cfg->{-by_newsgroup}->{$ngname};
				return ($ibx, $xnum) if $ibx;
				warn "W: `$ngname' does not exist for #$xnum\n";
			}
		}
		# no warning here, $mid is just invalid
	} else { # slow path for non-ALL users
		for my $ibx (values %{$pi_cfg->{-by_newsgroup}}) {
			next if defined $cur_ibx && $ibx eq $cur_ibx;
			my $n = $ibx->mm(1)->num_for($mid);
			return ($ibx, $n) if defined $n;
		}
	}
	(undef, undef);
}

sub xref_range_i {
	my ($self, $beg, $end) = @_;
	my $ibx = $self->{ibx};
	my $msgs = $ibx->over(1)->query_xover($$beg, $end);
	scalar(@$msgs) or return;
	$$beg = $msgs->[-1]->{num} + 1;
	$self->msg_more(join('', map {
		"$_->{num} ".xref($self, $ibx, $_) . "\r\n";
	} @$msgs));
	1;
}

sub hdr_xref ($$$) { # optimize XHDR Xref [range] for rtin
	my ($self, $xhdr, $range) = @_;

	if (defined $range && $range =~ $ONE_MSGID) {
		my $mid = $1;
		my ($ibx, $n) = mid_lookup($self, $mid);
		return r430 unless $n;
		my $smsg = $ibx->over(1)->get_art($n) or return;
		hdr_mid_response($self, $xhdr, $ibx, $n, $range,
				xref($self, $ibx, $smsg));
	} else { # numeric range
		$range = $self->{article} unless defined $range;
		my $r = get_range($self, $range);
		return $r unless ref $r;
		$self->msg_more($xhdr ? r221 : r225);
		long_response($self, \&xref_range_i, @$r);
	}
}

sub over_header_for {
	my ($ibx, $num, $field) = @_;
	my $smsg = $ibx->over(1)->get_art($num) or return;
	return PublicInbox::Smsg::date($smsg) if $field eq 'date';
	$smsg->{$field};
}

sub smsg_range_i {
	my ($self, $beg, $end, $field) = @_;
	my $msgs = $self->{ibx}->over(1)->query_xover($$beg, $end);
	scalar(@$msgs) or return;
	my $tmp = '';

	# ->{$field} is faster than ->$field invocations, so favor that.
	if ($field eq 'date') {
		for my $s (@$msgs) {
			$tmp .= "$s->{num} ".PublicInbox::Smsg::date($s)."\r\n"
		}
	} else {
		for my $s (@$msgs) {
			$tmp .= "$s->{num} $s->{$field}\r\n";
		}
	}
	utf8::encode($tmp);
	$self->msg_more($tmp);
	$$beg = $msgs->[-1]->{num} + 1;
}

sub hdr_smsg ($$$$) {
	my ($self, $xhdr, $field, $range) = @_;
	if (defined $range && $range =~ $ONE_MSGID) {
		my ($ibx, $n) = mid_lookup($self, $1);
		return r430 unless defined $n;
		my $v = over_header_for($ibx, $n, $field);
		hdr_mid_response($self, $xhdr, $ibx, $n, $range, $v);
	} else { # numeric range
		$range = $self->{article} unless defined $range;
		my $r = get_range($self, $range);
		return $r unless ref $r;
		$self->msg_more($xhdr ? r221 : r225);
		long_response($self, \&smsg_range_i, @$r, $field);
	}
}

sub do_hdr ($$$;$) {
	my ($self, $xhdr, $header, $range) = @_;
	my $sub = lc $header;
	if ($sub eq 'message-id') {
		hdr_message_id($self, $xhdr, $range);
	} elsif ($sub eq 'xref') {
		hdr_xref($self, $xhdr, $range);
	} elsif ($sub =~ /\A(?:subject|references|date|from|to|cc|
				bytes|lines)\z/x) {
		hdr_smsg($self, $xhdr, $sub, $range);
	} elsif ($sub =~ /\A:(bytes|lines)\z/) {
		hdr_smsg($self, $xhdr, $1, $range);
	} else {
		$xhdr ? (r221 . '.') : "503 HDR not permitted on $header";
	}
}

# RFC 3977
sub cmd_hdr ($$;$) {
	my ($self, $header, $range) = @_;
	do_hdr($self, 0, $header, $range);
}

# RFC 2980
sub cmd_xhdr ($$;$) {
	my ($self, $header, $range) = @_;
	do_hdr($self, 1, $header, $range);
}

sub hdr_mid_prefix ($$$$$) {
	my ($self, $xhdr, $ibx, $n, $mid) = @_;
	return $mid if $xhdr;

	# HDR for RFC 3977 users
	if (my $cur_ibx = $self->{ibx}) {
		($cur_ibx eq $ibx) ? $n : '0';
	} else {
		'0';
	}
}

sub hdr_mid_response ($$$$$$) {
	my ($self, $xhdr, $ibx, $n, $mid, $v) = @_;
	$self->write(($xhdr ? r221.$mid :
		   r225.hdr_mid_prefix($self, $xhdr, $ibx, $n, $mid)) .
		" $v\r\n.\r\n");
	undef;
}

sub xrover_i {
	my ($self, $beg, $end) = @_;
	my $h = over_header_for($self->{ibx}, $$beg, 'references');
	more($self, "$$beg $h") if defined($h);
	$$beg++ < $end;
}

sub cmd_xrover ($;$) {
	my ($self, $range) = @_;
	my $ibx = $self->{ibx} or return '412 no newsgroup selected';
	(defined $range && $range =~ /[<>]/) and
		return '420 No article(s) selected'; # no message IDs

	$range = $self->{article} unless defined $range;
	my $r = get_range($self, $range);
	return $r unless ref $r;
	more($self, '224 Overview information follows');
	long_response($self, \&xrover_i, @$r);
}

sub over_line ($$$) {
	my ($self, $ibx, $smsg) = @_;
	# n.b. field access and procedural calls can be
	# 10%-15% faster than OO method calls:
	my $s = join("\t", $smsg->{num},
		$smsg->{subject},
		$smsg->{from},
		PublicInbox::Smsg::date($smsg),
		"<$smsg->{mid}>",
		$smsg->{references},
		$smsg->{bytes},
		$smsg->{lines},
		"Xref: " . xref($self, $ibx, $smsg));
	utf8::encode($s);
	$s .= "\r\n";
}

sub cmd_over ($;$) {
	my ($self, $range) = @_;
	if ($range && $range =~ $ONE_MSGID) {
		my ($ibx, $n) = mid_lookup($self, $1);
		defined $n or return r430;
		my $smsg = $ibx->over(1)->get_art($n) or return r430;
		more($self, '224 Overview information follows (multi-line)');

		# Only set article number column if it's the current group
		# (RFC 3977 8.3.2)
		my $cur_ibx = $self->{ibx};
		if (!$cur_ibx || $cur_ibx ne $ibx) {
			# set {-orig_num} for nntp_xref_for
			$smsg->{-orig_num} = $smsg->{num};
			$smsg->{num} = 0;
		}
		$self->msg_more(over_line($self, $ibx, $smsg));
		'.';
	} else {
		cmd_xover($self, $range);
	}
}

sub xover_i {
	my ($self, $beg, $end) = @_;
	my $ibx = $self->{ibx};
	my $msgs = $ibx->over(1)->query_xover($$beg, $end);
	my $nr = scalar @$msgs or return;

	# OVERVIEW.FMT
	$self->msg_more(join('', map {
		over_line($self, $ibx, $_);
		} @$msgs));
	$$beg = $msgs->[-1]->{num} + 1;
}

sub cmd_xover ($;$) {
	my ($self, $range) = @_;
	$range = $self->{article} unless defined $range;
	my $r = get_range($self, $range);
	return $r unless ref $r;
	my ($beg, $end) = @$r;
	more($self, "224 Overview information follows for $$beg to $end");
	long_response($self, \&xover_i, @$r);
}

sub compressed { undef }

sub cmd_starttls ($) {
	my ($self) = @_;
	my $sock = $self->{sock} or return;
	# RFC 4642 2.2.1
	return r502 if ($sock->can('accept_SSL') || $self->compressed);
	my $opt = $self->{nntpd}->{accept_tls} or
		return '580 can not initiate TLS negotiation';
	$self->write(\"382 Continue with TLS negotiation\r\n");
	$self->{sock} = IO::Socket::SSL->start_SSL($sock, %$opt);
	$self->requeue if PublicInbox::DS::accept_tls_step($self);
	undef;
}

# RFC 8054
sub cmd_compress ($$) {
	my ($self, $alg) = @_;
	return '503 Only DEFLATE is supported' if uc($alg) ne 'DEFLATE';
	return r502 if $self->compressed;
	PublicInbox::NNTPdeflate->enable($self);
	$self->requeue;
	undef
}

sub zflush {} # overridden by NNTPdeflate

sub cmd_xpath ($$) {
	my ($self, $mid) = @_;
	return r501 unless $mid =~ $ONE_MSGID;
	$mid = $1;
	my @paths;
	my $pi_cfg = $self->{nntpd}->{pi_cfg};
	my $groups = $pi_cfg->{-by_newsgroup};
	if (my $ALL = $pi_cfg->ALL) {
		my ($id, $prev, %seen);
		while (my $smsg = $ALL->over->next_by_mid($mid, \$id, \$prev)) {
			my $xr3 = $ALL->over->get_xref3($smsg->{num});
			for my $x (@$xr3) {
				my ($ngname, $n) = split(/:/, $x);
				$x = "$ngname/$n";
				if ($groups->{$ngname} && !$seen{$x}++) {
					push(@paths, $x);
				}
			}
		}
	} else { # slow path, no point in using long_response
		for my $ibx (values %$groups) {
			my $n = $ibx->mm(1)->num_for($mid) // next;
			push @paths, "$ibx->{newsgroup}/$n";
		}
	}
	return '430 no such article on server' unless @paths;
	'223 '.join(' ', sort(@paths));
}

sub res ($$) { do_write($_[0], $_[1] . "\r\n") }

sub more ($$) { $_[0]->msg_more($_[1] . "\r\n") }

sub do_write ($$) {
	my $self = $_[0];
	my $done = $self->write(\($_[1]));
	return 0 unless $self->{sock};

	$done;
}

sub err ($$;@) {
	my ($self, $fmt, @args) = @_;
	printf { $self->{nntpd}->{err} } $fmt."\n", @args;
}

sub out ($$;@) {
	my ($self, $fmt, @args) = @_;
	printf { $self->{nntpd}->{out} } $fmt."\n", @args;
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
	my $fd = fileno($self->{sock});
	my $r = eval { process_line($self, $line) };
	my $pending = $self->{wbuf} ? ' pending' : '';
	out($self, "[$fd] %s - %0.6f$pending", $line, now() - $t0);
	return $self->close if $r < 0;
	$self->rbuf_idle($rbuf);

	# maybe there's more pipelined data, or we'll have
	# to register it for socket-readiness notifications
	$self->requeue unless $pending;
}

sub busy { # for graceful shutdown in PublicInbox::Daemon:
	my ($self) = @_;
	defined($self->{rbuf}) || defined($self->{wbuf})
}

1;
