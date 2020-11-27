# Copyright (C) 2015-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Each instance of this represents a NNTP client socket
# fields:
# nntpd: PublicInbox::NNTPD ref
# article: per-session current article number
# ng: PublicInbox::Inbox ref
# long_cb: long_response private data
package PublicInbox::NNTP;
use strict;
use parent qw(PublicInbox::DS);
use PublicInbox::MID qw(mid_escape $MID_EXTRACT);
use PublicInbox::Eml;
use POSIX qw(strftime);
use PublicInbox::DS qw(now);
use Digest::SHA qw(sha1_hex);
use Time::Local qw(timegm timelocal);
use PublicInbox::GitAsyncCat;
use constant {
	LINE_MAX => 512, # RFC 977 section 2.3
	r501 => '501 command syntax error',
	r502 => '502 Command unavailable',
	r221 => '221 Header follows',
	r224 => '224 Overview information follows (multi-line)',
	r225 =>	'225 Headers follow (multi-line)',
	r430 => '430 No article with that message-id',
};
use PublicInbox::Syscall qw(EPOLLIN EPOLLONESHOT);
use Errno qw(EAGAIN);
my $ONE_MSGID = qr/\A$MID_EXTRACT\z/;
my @OVERVIEW = qw(Subject From Date Message-ID References);
my $OVERVIEW_FMT = join(":\r\n", @OVERVIEW, qw(Bytes Lines), '') .
		"Xref:full\r\n";
my $LIST_HEADERS = join("\r\n", @OVERVIEW,
			qw(:bytes :lines Xref To Cc)) . "\r\n";
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
	$self->update_idle_time;
	$self;
}

sub args_ok ($$) {
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
	my ($req, @args) = split(/[ \t]+/, $l);
	return 1 unless defined($req); # skip blank line
	$req = $self->can('cmd_'.lc($req));
	return res($self, '500 command not recognized') unless $req;
	return res($self, r501) unless args_ok($req, scalar @args);

	my $res = eval { $req->($self, @args) };
	my $err = $@;
	if ($err && $self->{sock}) {
		local $/ = "\n";
		chomp($l);
		err($self, 'error from: %s (%s)', $l, $err);
		$res = '503 program fault - command not performed';
	}
	return 0 unless defined $res;
	res($self, $res);
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
	$arg = uc $arg;
	return r501 unless $arg eq 'READER';
	'201 Posting prohibited';
}

sub cmd_slave ($) { '202 slave status noted' }

sub cmd_xgtitle ($;$) {
	my ($self, $wildmat) = @_;
	more($self, '282 list of groups and descriptions follows');
	list_newsgroups($self, $wildmat);
	'.'
}

sub list_overview_fmt ($) {
	my ($self) = @_;
	$self->msg_more($OVERVIEW_FMT);
}

sub list_headers ($;$) {
	my ($self) = @_;
	$self->msg_more($LIST_HEADERS);
}

sub list_active ($;$) {
	my ($self, $wildmat) = @_;
	wildmat2re($wildmat);
	my $groups = $self->{nntpd}->{groups};
	for my $ngname (grep(/$wildmat/, @{$self->{nntpd}->{groupnames}})) {
		group_line($self, $groups->{$ngname});
	}
}

sub list_active_times ($;$) {
	my ($self, $wildmat) = @_;
	wildmat2re($wildmat);
	my $groups = $self->{nntpd}->{groups};
	for my $ngname (grep(/$wildmat/, @{$self->{nntpd}->{groupnames}})) {
		my $ibx = $groups->{$ngname};
		my $c = eval { $ibx->uidvalidity } // time;
		more($self, "$ngname $c $ibx->{-primary_address}");
	}
}

sub list_newsgroups ($;$) {
	my ($self, $wildmat) = @_;
	wildmat2re($wildmat);
	my $groups = $self->{nntpd}->{groups};
	for my $ngname (grep(/$wildmat/, @{$self->{nntpd}->{groupnames}})) {
		more($self, "$ngname ".$groups->{$ngname}->description);
	}
}

# LIST SUBSCRIPTIONS, DISTRIB.PATS are not supported
sub cmd_list ($;$$) {
	my ($self, @args) = @_;
	if (scalar @args) {
		my $arg = shift @args;
		$arg =~ tr/A-Z./a-z_/;
		$arg = "list_$arg";
		$arg = $self->can($arg);
		return r501 unless $arg && args_ok($arg, scalar @args);
		more($self, '215 information follows');
		$arg->($self, @args);
	} else {
		more($self, '215 list of newsgroups follows');
		foreach my $ng (@{$self->{nntpd}->{grouplist}}) {
			group_line($self, $ng);
		}
	}
	'.'
}

sub listgroup_range_i {
	my ($self, $beg, $end) = @_;
	my $r = $self->{ng}->mm->msg_range($beg, $end, 'num');
	scalar(@$r) or return;
	more($self, join("\r\n", map { $_->[0] } @$r));
	1;
}

sub listgroup_all_i {
	my ($self, $num) = @_;
	my $ary = $self->{ng}->mm->ids_after($num);
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
	$self->{ng} or return '412 no newsgroup selected';
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
	if (bytes::length($date) == 8) { # RFC 3977 allows YYYYMMDD
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
	my ($self, $ng) = @_;
	my ($min, $max) = $ng->mm->minmax;
	more($self, "$ng->{newsgroup} $max $min n");
}

sub cmd_newgroups ($$$;$$) {
	my ($self, $date, $time, $gmt, $dists) = @_;
	my $ts = eval { parse_time($date, $time, $gmt) };
	return r501 if $@;

	# TODO dists
	more($self, '231 list of new newsgroups follows');
	foreach my $ng (@{$self->{nntpd}->{grouplist}}) {
		my $c = eval { $ng->uidvalidity } // 0;
		next unless $c > $ts;
		group_line($self, $ng);
	}
	'.'
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
	my ($self, $overs, $ts, $prev) = @_;
	my $over = $overs->[0];
	my $msgs = $over->query_ts($ts, $$prev);
	if (scalar @$msgs) {
		more($self, '<' .
			join(">\r\n<", map { $_->{mid} } @$msgs ).
			'>');
		$$prev = $msgs->[-1]->{num};
	} else {
		shift @$overs;
		if (@$overs) { # continue onto next newsgroup
			$$prev = 0;
			return 1;
		} else { # break out of the long response.
			return;
		}
	}
}

sub cmd_newnews ($$$$;$$) {
	my ($self, $newsgroups, $date, $time, $gmt, $dists) = @_;
	my $ts = eval { parse_time($date, $time, $gmt) };
	return r501 if $@;
	more($self, '230 list of new articles by message-id follows');
	my ($keep, $skip) = split('!', $newsgroups, 2);
	ngpat2re($keep);
	ngpat2re($skip);
	my @overs;
	foreach my $ng (@{$self->{nntpd}->{grouplist}}) {
		$ng->{newsgroup} =~ $keep or next;
		$ng->{newsgroup} =~ $skip and next;
		my $over = $ng->over or next;
		push @overs, $over;
	};
	return '.' unless @overs;

	my $prev = 0;
	long_response($self, \&newnews_i, \@overs, $ts, \$prev);
}

sub cmd_group ($$) {
	my ($self, $group) = @_;
	my $no_such = '411 no such news group';
	my $nntpd = $self->{nntpd};
	my $ng = $nntpd->{groups}->{$group} or return $no_such;
	$nntpd->idler_start;

	$self->{ng} = $ng;
	my ($min, $max) = $ng->mm->minmax;
	$self->{article} = $min;
	my $est_size = $max - $min;
	"211 $est_size $min $max $group";
}

sub article_adj ($$) {
	my ($self, $off) = @_;
	my $ng = $self->{ng} or return '412 no newsgroup selected';

	my $n = $self->{article};
	defined $n or return '420 no current article has been selected';

	$n += $off;
	my $mid = $ng->mm->mid_for($n);
	unless ($mid) {
		$n = $off > 0 ? 'next' : 'previous';
		return "421 no $n article in this group";
	}
	$self->{article} = $n;
	"223 $n <$mid> article retrieved - request text separately";
}

sub cmd_next ($) { article_adj($_[0], 1) }
sub cmd_last ($) { article_adj($_[0], -1) }

# We want to encourage using email and CC-ing everybody involved to avoid
# the single-point-of-failure a single server provides.
sub cmd_post ($) {
	my ($self) = @_;
	my $ng = $self->{ng};
	$ng ? "440 mailto:$ng->{-primary_address} to post"
		: '440 posting not allowed'
}

sub cmd_quit ($) {
	my ($self) = @_;
	res($self, '205 closing connection - goodbye!');
	$self->shutdn;
	undef;
}

sub header_append ($$$) {
	my ($hdr, $k, $v) = @_;
	my @v = $hdr->header_raw($k);
	foreach (@v) {
		return if $v eq $_;
	}
	$hdr->header_set($k, @v, $v);
}

sub xref ($$$$) {
	my ($self, $ng, $n, $mid) = @_;
	my $ret = $self->{nntpd}->{servername} . " $ng->{newsgroup}:$n";

	# num_for is pretty cheap and sometimes we'll lookup the existence
	# of an article without getting even the OVER info.  In other words,
	# I'm not sure if its worth optimizing by scanning To:/Cc: and
	# PublicInbox::ExtMsg on the PSGI end is just as expensive
	foreach my $other (@{$self->{nntpd}->{grouplist}}) {
		next if $ng eq $other;
		my $num = eval { $other->mm->num_for($mid) } or next;
		$ret .= " $other->{newsgroup}:$num";
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
	my $xref = xref($smsg->{nntp}, $ibx, $smsg->{num}, $mid);
	$hdr->header_set('Xref', $xref);

	# RFC 5536 3.1.4
	my ($server_name, $newsgroups) = split(/ /, $xref, 2);
	$newsgroups =~ s/:[0-9]+\b//g; # drop NNTP article numbers
	$newsgroups =~ tr/ /,/;
	$hdr->header_set('Newsgroups', $newsgroups);

	# *something* here is required for leafnode, try to follow
	# RFC 5536 3.1.5...
	$hdr->header_set('Path', $server_name . '!not-for-mail');

	header_append($hdr, 'List-Post', "<mailto:$ibx->{-primary_address}>");
	if (my $url = $ibx->base_url) {
		$mid = mid_escape($mid);
		header_append($hdr, 'Archived-At', "<$url$mid/>");
		header_append($hdr, 'List-Archive', "<$url>");
	}
}

sub art_lookup ($$$) {
	my ($self, $art, $code) = @_;
	my $ng = $self->{ng};
	my ($n, $mid);
	my $err;
	if (defined $art) {
		if ($art =~ /\A[0-9]+\z/) {
			$err = '423 no such article number in this group';
			$n = int($art);
			goto find_mid;
		} elsif ($art =~ $ONE_MSGID) {
			$mid = $1;
			$err = r430;
			$n = $ng->mm->num_for($mid) if $ng;
			goto found if defined $n;
			foreach my $g (values %{$self->{nntpd}->{groups}}) {
				$n = $g->mm->num_for($mid);
				if (defined $n) {
					$ng = $g;
					goto found;
				}
			}
			return $err;
		} else {
			return r501;
		}
	} else {
		$err = '420 no current article has been selected';
		$n = $self->{article};
		defined $n or return $err;
find_mid:
		$ng or return '412 no newsgroup has been selected';
		$mid = $ng->mm->mid_for($n);
		defined $mid or return $err;
	}
found:
	my $smsg = $ng->over->get_art($n) or return $err;
	$smsg->{-ibx} = $ng;
	if ($code == 223) { # STAT
		set_art($self, $n);
		"223 $n <$smsg->{mid}> article retrieved - " .
			"request text separately";
	} else { # HEAD | BODY | ARTICLE
		$smsg->{nntp} = $self;
		$smsg->{nntp_code} = $code;
		set_art($self, $art);
		# this dereferences to `undef'
		${git_async_cat($ng->git, $smsg->{blob}, \&blob_cb, $smsg)};
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

sub blob_cb { # called by git->cat_async via git_async_cat
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
	my $ng = $self->{ng} or return '412 no news group has been selected';
	defined $range or return '420 No article(s) selected';
	my ($beg, $end);
	my ($min, $max) = $ng->mm->minmax;
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
		res($self, '.');
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
	my $r = $self->{ng}->mm->msg_range($beg, $end);
	@$r or return;
	more($self, join("\r\n", map { "$_->[0] <$_->[1]>" } @$r));
	1;
}

sub hdr_message_id ($$$) { # optimize XHDR Message-ID [range] for slrnpull.
	my ($self, $xhdr, $range) = @_;

	if (defined $range && $range =~ $ONE_MSGID) {
		my ($ng, $n) = mid_lookup($self, $1);
		return r430 unless $n;
		hdr_mid_response($self, $xhdr, $ng, $n, $range, $range);
	} else { # numeric range
		$range = $self->{article} unless defined $range;
		my $r = get_range($self, $range);
		return $r unless ref $r;
		more($self, $xhdr ? r221 : r225);
		long_response($self, \&hdr_msgid_range_i, @$r);
	}
}

sub mid_lookup ($$) {
	my ($self, $mid) = @_;
	my $self_ng = $self->{ng};
	if ($self_ng) {
		my $n = $self_ng->mm->num_for($mid);
		return ($self_ng, $n) if defined $n;
	}
	foreach my $ng (values %{$self->{nntpd}->{groups}}) {
		next if defined $self_ng && $ng eq $self_ng;
		my $n = $ng->mm->num_for($mid);
		return ($ng, $n) if defined $n;
	}
	(undef, undef);
}

sub xref_range_i {
	my ($self, $beg, $end) = @_;
	my $ng = $self->{ng};
	my $r = $ng->mm->msg_range($beg, $end);
	@$r or return;
	more($self, join("\r\n", map {
		my $num = $_->[0];
		"$num ".xref($self, $ng, $num, $_->[1]);
	} @$r));
	1;
}

sub hdr_xref ($$$) { # optimize XHDR Xref [range] for rtin
	my ($self, $xhdr, $range) = @_;

	if (defined $range && $range =~ $ONE_MSGID) {
		my $mid = $1;
		my ($ng, $n) = mid_lookup($self, $mid);
		return r430 unless $n;
		hdr_mid_response($self, $xhdr, $ng, $n, $range,
				xref($self, $ng, $n, $mid));
	} else { # numeric range
		$range = $self->{article} unless defined $range;
		my $r = get_range($self, $range);
		return $r unless ref $r;
		more($self, $xhdr ? r221 : r225);
		long_response($self, \&xref_range_i, @$r);
	}
}

sub over_header_for {
	my ($over, $num, $field) = @_;
	my $smsg = $over->get_art($num) or return;
	return PublicInbox::Smsg::date($smsg) if $field eq 'date';
	$smsg->{$field};
}

sub smsg_range_i {
	my ($self, $beg, $end, $field) = @_;
	my $over = $self->{ng}->over;
	my $msgs = $over->query_xover($$beg, $end);
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
		my ($ng, $n) = mid_lookup($self, $1);
		return r430 unless defined $n;
		my $v = over_header_for($ng->over, $n, $field);
		hdr_mid_response($self, $xhdr, $ng, $n, $range, $v);
	} else { # numeric range
		$range = $self->{article} unless defined $range;
		my $r = get_range($self, $range);
		return $r unless ref $r;
		more($self, $xhdr ? r221 : r225);
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
		$xhdr ? (r221 . "\r\n.") : "503 HDR not permitted on $header";
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
	my ($self, $xhdr, $ng, $n, $mid) = @_;
	return $mid if $xhdr;

	# HDR for RFC 3977 users
	if (my $self_ng = $self->{ng}) {
		($self_ng eq $ng) ? $n : '0';
	} else {
		'0';
	}
}

sub hdr_mid_response ($$$$$$) {
	my ($self, $xhdr, $ng, $n, $mid, $v) = @_;
	my $res = '';
	if ($xhdr) {
		$res .= r221 . "\r\n";
		$res .= "$mid $v\r\n";
	} else {
		$res .= r225 . "\r\n";
		my $pfx = hdr_mid_prefix($self, $xhdr, $ng, $n, $mid);
		$res .= "$pfx $v\r\n";
	}
	res($self, $res .= '.');
	undef;
}

sub xrover_i {
	my ($self, $beg, $end) = @_;
	my $h = over_header_for($self->{ng}->over, $$beg, 'references');
	more($self, "$$beg $h") if defined($h);
	$$beg++ < $end;
}

sub cmd_xrover ($;$) {
	my ($self, $range) = @_;
	my $ng = $self->{ng} or return '412 no newsgroup selected';
	(defined $range && $range =~ /[<>]/) and
		return '420 No article(s) selected'; # no message IDs

	$range = $self->{article} unless defined $range;
	my $r = get_range($self, $range);
	return $r unless ref $r;
	more($self, '224 Overview information follows');
	long_response($self, \&xrover_i, @$r);
}

sub over_line ($$$$) {
	my ($self, $ng, $num, $smsg) = @_;
	# n.b. field access and procedural calls can be
	# 10%-15% faster than OO method calls:
	my $s = join("\t", $num,
		$smsg->{subject},
		$smsg->{from},
		PublicInbox::Smsg::date($smsg),
		"<$smsg->{mid}>",
		$smsg->{references},
		$smsg->{bytes},
		$smsg->{lines},
		"Xref: " . xref($self, $ng, $num, $smsg->{mid}));
	utf8::encode($s);
	$s
}

sub cmd_over ($;$) {
	my ($self, $range) = @_;
	if ($range && $range =~ $ONE_MSGID) {
		my ($ng, $n) = mid_lookup($self, $1);
		defined $n or return r430;
		my $smsg = $ng->over->get_art($n) or return r430;
		more($self, '224 Overview information follows (multi-line)');

		# Only set article number column if it's the current group
		my $self_ng = $self->{ng};
		$n = 0 if (!$self_ng || $self_ng ne $ng);
		more($self, over_line($self, $ng, $n, $smsg));
		'.';
	} else {
		cmd_xover($self, $range);
	}
}

sub xover_i {
	my ($self, $beg, $end) = @_;
	my $ng = $self->{ng};
	my $msgs = $ng->over->query_xover($$beg, $end);
	my $nr = scalar @$msgs or return;

	# OVERVIEW.FMT
	more($self, join("\r\n", map {
		over_line($self, $ng, $_->{num}, $_);
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
	res($self, '382 Continue with TLS negotiation');
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
	foreach my $ng (values %{$self->{nntpd}->{groups}}) {
		my $n = $ng->mm->num_for($mid);
		push @paths, "$ng->{newsgroup}/$n" if defined $n;
	}
	return '430 no such article on server' unless @paths;
	'223 '.join(' ', @paths);
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
	out($self, "[$fd] %s - %0.6f$pending", $line, now() - $t0);
	return $self->close if $r < 0;
	$self->rbuf_idle($rbuf);
	$self->update_idle_time;

	# maybe there's more pipelined data, or we'll have
	# to register it for socket-readiness notifications
	$self->requeue unless $pending;
}

# for graceful shutdown in PublicInbox::Daemon:
sub busy {
	my ($self, $now) = @_;
	($self->{rbuf} || $self->{wbuf} || $self->not_idle_long($now));
}

1;
