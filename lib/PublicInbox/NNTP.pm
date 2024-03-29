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
	r501 => "501 command syntax error\r\n",
	r502 => "502 Command unavailable\r\n",
	r221 => "221 Header follows\r\n",
	r225 =>	"225 Headers follow (multi-line)\r\n",
	r430 => "430 No article with that message-id\r\n",
};
use Errno qw(EAGAIN);
my $ONE_MSGID = qr/\A$MID_EXTRACT\z/;
my @OVERVIEW = qw(Subject From Date Message-ID References);
my $OVERVIEW_FMT = join(":\r\n", @OVERVIEW, qw(Bytes Lines), '') .
		"Xref:full\r\n.\r\n";
my $LIST_HEADERS = join("\r\n", @OVERVIEW,
			qw(:bytes :lines Xref To Cc)) . "\r\n.\r\n";
my $CAPABILITIES = <<"";
101 Capability list:\r
VERSION 2\r
READER\r
NEWNEWS\r
LIST ACTIVE ACTIVE.TIMES NEWSGROUPS OVERVIEW.FMT\r
HDR\r
OVER\r
COMPRESS DEFLATE\r

sub do_greet ($) { $_[0]->write($_[0]->{nntpd}->{greet}) };

sub new {
	my ($cls, $sock, $nntpd) = @_;
	(bless { nntpd => $nntpd }, $cls)->greet($sock)
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
	return $self->write(\r501) unless args_ok($req, scalar @args);
	my $res = eval { $req->($self, @args) };
	my $err = $@;
	if ($err && $self->{sock}) {
		$l =~ s/\r?\n//s;
		warn("error from: $l ($err)\n");
		$res = \"503 program fault - command not performed\r\n";
	}
	defined($res) ? $self->write($res) : 0;
}

# The keyword argument is not used (rfc3977 5.2.2)
sub cmd_capabilities ($;$) {
	my ($self, undef) = @_;
	my $res = $CAPABILITIES;
	if (!$self->{sock}->can('accept_SSL') &&
			$self->{nntpd}->{ssl_ctx_opt}) {
		$res .= "STARTTLS\r\n";
	}
	$res .= ".\r\n";
}

sub cmd_mode ($$) {
	my ($self, $arg) = @_;
	uc($arg) eq 'READER' ? \"201 Posting prohibited\r\n" : \r501;
}

sub cmd_slave ($) { \"202 slave status noted\r\n" }

sub cmd_xgtitle ($;$) {
	my ($self, $wildmat) = @_;
	$self->msg_more("282 list of groups and descriptions follows\r\n");
	list_newsgroups($self, $wildmat);
}

sub list_overview_fmt ($) { $OVERVIEW_FMT }

sub list_headers ($;$) { $LIST_HEADERS }

sub names2ibx ($;$) {
	my ($self, $names) = @_;
	my $groups = $self->{nntpd}->{pi_cfg}->{-by_newsgroup};
	if ($names) { # modify arrayref in-place
		$_ = $groups->{$_} for @$names;
		$names; # now an arrayref of ibx
	} else {
		my @ret = map { $groups->{$_} } @{$self->{nntpd}->{groupnames}};
		\@ret;
	}
}

sub list_active_i { # "LIST ACTIVE" and also just "LIST" (no args)
	my ($self, $ibxs) = @_;
	my @window = splice(@$ibxs, 0, 1000);
	emit_group_lines($self, \@window);
	scalar @$ibxs; # continue if there's more
}

sub list_active ($;$) { # called by cmd_list
	my ($self, $wildmat) = @_;
	wildmat2re($wildmat);
	my @names = grep(/$wildmat/, @{$self->{nntpd}->{groupnames}});
	$self->long_response(\&list_active_i, names2ibx($self, \@names));
}

sub list_active_times_i {
	my ($self, $ibxs) = @_;
	my @window = splice(@$ibxs, 0, 1000);
	$self->msg_more(join('', map {
		my $c = eval { $_->uidvalidity } // time;
		"$_->{newsgroup} $c <$_->{-primary_address}>\r\n";
	} @window));
	scalar @$ibxs; # continue if there's more
}

sub list_active_times ($;$) { # called by cmd_list
	my ($self, $wildmat) = @_;
	wildmat2re($wildmat);
	my @names = grep(/$wildmat/, @{$self->{nntpd}->{groupnames}});
	$self->long_response(\&list_active_times_i, names2ibx($self, \@names));
}

sub list_newsgroups_i {
	my ($self, $ibxs) = @_;
	my @window = splice(@$ibxs, 0, 1000);
	$self->msg_more(join('', map {
		"$_->{newsgroup} ".$_->description."\r\n"
	} @window));
	scalar @$ibxs; # continue if there's more
}

sub list_newsgroups ($;$) { # called by cmd_list
	my ($self, $wildmat) = @_;
	wildmat2re($wildmat);
	my @names = grep(/$wildmat/, @{$self->{nntpd}->{groupnames}});
	$self->long_response(\&list_newsgroups_i, names2ibx($self, \@names));
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
		$self->msg_more("215 information follows\r\n");
		$arg->($self, @args);
	} else {
		$self->msg_more("215 list of newsgroups follows\r\n");
		$self->long_response(\&list_active_i, names2ibx($self));
	}
}

sub listgroup_range_i {
	my ($self, $beg, $end) = @_;
	my $r = $self->{ibx}->mm(1)->msg_range($beg, $end, 'num');
	scalar(@$r) or return;
	$self->msg_more(join("\r\n", @$r, ''));
	1;
}

sub listgroup_all_i {
	my ($self, $num) = @_;
	my $ary = $self->{ibx}->over(1)->ids_after($num);
	scalar(@$ary) or return;
	$self->msg_more(join("\r\n", @$ary, ''));
	1;
}

sub cmd_listgroup ($;$$) {
	my ($self, $group, $range) = @_;
	if (defined $group) {
		my $res = cmd_group($self, $group);
		return $res if ref($res); # error if const strref
		$self->msg_more($res);
	}
	$self->{ibx} or return \"412 no newsgroup selected\r\n";
	if (defined $range) {
		my $r = get_range($self, $range);
		return $r unless ref $r;
		$self->long_response(\&listgroup_range_i, @$r);
	} else { # grab every article number
		$self->long_response(\&listgroup_all_i, \(my $num = 0));
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

sub emit_group_lines {
	my ($self, $ibxs) = @_;
	my ($min, $max);
	my $ALL = $self->{nntpd}->{pi_cfg}->ALL;
	my $misc = $ALL->misc if $ALL;
	my $buf = '';
	for my $ibx (@$ibxs) {
		$misc ? $misc->inbox_data($ibx) :
			delete(@$ibx{qw(-art_min -art_max)});
		($min, $max) = ($ibx->art_min, $ibx->art_max);
		$buf .= "$ibx->{newsgroup} $max $min n\r\n";
	}
	$self->msg_more($buf);
}

sub newgroups_i {
	my ($self, $ts, $ibxs) = @_;
	my @window = splice(@$ibxs, 0, 1000);
	@window = grep { (eval { $_->uidvalidity } // 0) > $ts } @window;
	emit_group_lines($self, \@window);
	scalar @$ibxs; # any more?
}

sub cmd_newgroups ($$$;$$) {
	my ($self, $date, $time, $gmt, $dists) = @_;
	my $ts = eval { parse_time($date, $time, $gmt) };
	return r501 if $@;

	# TODO dists
	$self->msg_more("231 list of new newsgroups follows\r\n");
	$self->long_response(\&newgroups_i, $ts, names2ibx($self));
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
	my ($self, $ibxs, $ts, $prev) = @_;
	if (my $over = $ibxs->[0]->over) {
		my $msgs = $over->query_ts($ts, $$prev);
		if (scalar @$msgs) {
			$self->msg_more(join('', map {
						"<$_->{mid}>\r\n";
					} @$msgs));
			$$prev = $msgs->[-1]->{num};
			return 1; # continue on current group
		}
	}
	shift @$ibxs;
	if (@$ibxs) { # continue onto next newsgroup
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
	$self->msg_more("230 list of new articles by message-id follows\r\n");
	my ($keep, $skip) = split(/!/, $newsgroups, 2);
	ngpat2re($keep);
	ngpat2re($skip);
	my @names = grep(/$keep/, @{$self->{nntpd}->{groupnames}});
	@names = grep(!/$skip/, @names);
	return \".\r\n" unless scalar(@names);
	my $prev = 0;
	$self->long_response(\&newnews_i, names2ibx($self, \@names),
				$ts, \$prev);
}

sub cmd_group ($$) {
	my ($self, $group) = @_;
	my $nntpd = $self->{nntpd};
	my $ibx = $nntpd->{pi_cfg}->{-by_newsgroup}->{$group} or
		return \"411 no such news group\r\n";
	$nntpd->idler_start;

	$self->{ibx} = $ibx;
	my ($min, $max) = $ibx->mm(1)->minmax;
	$self->{article} = $min;
	my $est_size = $max - $min;
	"211 $est_size $min $max $group\r\n";
}

sub article_adj ($$) {
	my ($self, $off) = @_;
	my $ibx = $self->{ibx} // return \"412 no newsgroup selected\r\n";
	my $n = $self->{article} //
		return \"420 no current article has been selected\r\n";

	$n += $off;
	my $mid = $ibx->mm(1)->mid_for($n) // do {
		$n = $off > 0 ? 'next' : 'previous';
		return "421 no $n article in this group\r\n";
	};
	$self->{article} = $n;
	"223 $n <$mid> article retrieved - request text separately\r\n";
}

sub cmd_next ($) { article_adj($_[0], 1) }
sub cmd_last ($) { article_adj($_[0], -1) }

# We want to encourage using email and CC-ing everybody involved to avoid
# the single-point-of-failure a single server provides.
sub cmd_post ($) {
	my ($self) = @_;
	my $ibx = $self->{ibx};
	$ibx ? "440 mailto:$ibx->{-primary_address} to post\r\n"
		: \"440 posting not allowed\r\n"
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
			$err = \"423 no such article number in this group\r\n";
			$n = int($art);
			goto find_ibx;
		} elsif ($art =~ $ONE_MSGID) {
			($ibx, $n) = mid_lookup($self, $1);
			goto found if $ibx;
			return \r430;
		} else {
			return \r501;
		}
	} else {
		$err = \"420 no current article has been selected\r\n";
		$n = $self->{article} // return $err;
find_ibx:
		$ibx = $self->{ibx} or
			return \"412 no newsgroup has been selected\r\n";
	}
found:
	my $smsg = $ibx->over(1)->get_art($n) or return $err;
	$smsg->{-ibx} = $ibx;
	if ($code == 223) { # STAT
		set_art($self, $n);
		"223 $n <$smsg->{mid}> article retrieved - " .
			"request text separately\r\n";
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
	$$msg .= "\r\n" unless substr($$msg, -2, 2) eq "\r\n";
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
		$self->msg_more($r .= "head and body follow\r\n");
		msg_hdr_write($eml, $smsg);
		$self->msg_more("\r\n");
		msg_body_write($self, $bref);
	} elsif ($code == 221) {
		$self->msg_more($r .= "head follows\r\n");
		msg_hdr_write($eml, $smsg);
	} elsif ($code == 222) {
		$self->msg_more($r .= "body follows\r\n");
		msg_body_write($self, $bref);
	} else {
		$self->close;
		die "BUG: bad code: $r";
	}
	$self->write(\".\r\n"); # flushes (includes ->dflush)
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

sub cmd_ihave ($) { \"435 article not wanted - do not send it\r\n" }

sub cmd_date ($) { '111 '.strftime('%Y%m%d%H%M%S', gmtime(time))."\r\n" }

sub cmd_help ($) { \"100 help text follows\r\n.\r\n" }

# returns a ref on success
sub get_range ($$) {
	my ($self, $range) = @_;
	my $ibx = $self->{ibx} //
		return "412 no news group has been selected\r\n";
	$range // return "420 No article(s) selected\r\n";
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
	$beg > $end ? "420 No article(s) selected\r\n" : [ \$beg, $end ];
}

sub long_response_done { $_[0]->write(\".\r\n") } # overrides superclass

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
		$self->long_response(\&hdr_msgid_range_i, @$r);
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
		$self->long_response(\&xref_range_i, @$r);
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
		$self->long_response(\&smsg_range_i, @$r, $field);
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
		$xhdr ? (r221.".\r\n") : "503 HDR not permitted on $header\r\n";
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
	$self->msg_more("$$beg $h\r\n") if defined($h);
	$$beg++ < $end;
}

sub cmd_xrover ($;$) {
	my ($self, $range) = @_;
	my $ibx = $self->{ibx} or return \"412 no newsgroup selected\r\n";
	(defined $range && $range =~ /[<>]/) and
		return \"420 No article(s) selected\r\n"; # no message IDs

	$range = $self->{article} unless defined $range;
	my $r = get_range($self, $range);
	return $r unless ref $r;
	$self->msg_more("224 Overview information follows\r\n");
	$self->long_response(\&xrover_i, @$r);
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
		$self->msg_more(
			"224 Overview information follows (multi-line)\r\n");

		# Only set article number column if it's the current group
		# (RFC 3977 8.3.2)
		my $cur_ibx = $self->{ibx};
		if (!$cur_ibx || $cur_ibx ne $ibx) {
			# set {-orig_num} for nntp_xref_for
			$smsg->{-orig_num} = $smsg->{num};
			$smsg->{num} = 0;
		}
		over_line($self, $ibx, $smsg).".\r\n";
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
	$self->msg_more(
		"224 Overview information follows for $$beg to $end\r\n");
	$self->long_response(\&xover_i, @$r);
}

sub cmd_starttls ($) {
	my ($self) = @_;
	# RFC 4642 2.2.1
	(($self->{sock} // return)->can('stop_SSL') || $self->compressed) and
		return r502;
	$self->{nntpd}->{ssl_ctx_opt} or
		return \"580 can not initiate TLS negotiation\r\n";
	$self->write(\"382 Continue with TLS negotiation\r\n");
	PublicInbox::TLS::start($self->{sock}, $self->{nntpd});
	$self->requeue if PublicInbox::DS::accept_tls_step($self);
	undef;
}

# RFC 8054
sub cmd_compress ($$) {
	my ($self, $alg) = @_;
	return "503 Only DEFLATE is supported\r\n" if uc($alg) ne 'DEFLATE';
	return r502 if $self->compressed;
	PublicInbox::NNTPdeflate->enable($self) or return
				\"403 Unable to activate compression\r\n";
	PublicInbox::DS::write($self, \"206 Compression active\r\n");
	$self->requeue;
	undef
}

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
	return \"430 no such article on server\r\n" unless @paths;
	'223 '.join(' ', sort(@paths))."\r\n";
}

sub out ($$;@) {
	my ($self, $fmt, @args) = @_;
	printf { $self->{nntpd}->{out} } $fmt."\n", @args;
}

# callback used by PublicInbox::DS for any (e)poll (in/out/hup/err)
sub event_step {
	my ($self) = @_;
	local $SIG{__WARN__} = $self->{nntpd}->{warn_cb};
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

package PublicInbox::NNTPdeflate;
use PublicInbox::DSdeflate;
our @ISA = qw(PublicInbox::DSdeflate PublicInbox::NNTP);

1;
