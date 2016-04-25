# Copyright (C) 2015 all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
#
# Each instance of this represents a NNTP client socket
package PublicInbox::NNTP;
use strict;
use warnings;
use base qw(Danga::Socket);
use fields qw(nntpd article rbuf ng long_res);
use PublicInbox::Search;
use PublicInbox::Msgmap;
use PublicInbox::Git;
use PublicInbox::MID qw(mid2path);
use Email::MIME;
use Data::Dumper qw(Dumper);
use POSIX qw(strftime);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
use constant {
	r501 => '501 command syntax error',
	r221 => '221 Header follows',
	r224 => '224 Overview information follows (multi-line)',
	r225 =>	'225 Headers follow (multi-line)',
	r430 => '430 No article with that message-id',
	long_response_limit => 0xffffffff,
};

sub now () { clock_gettime(CLOCK_MONOTONIC) };

my @OVERVIEW = qw(Subject From Date Message-ID References);
my $OVERVIEW_FMT = join(":\r\n", @OVERVIEW, qw(Bytes Lines)) . ":\r\n";
my $LIST_HEADERS = join("\r\n", @OVERVIEW,
			qw(:bytes :lines Xref To Cc)) . "\r\n";

# disable commands with easy DoS potential:
# LISTGROUP could get pretty bad, too...
my %DISABLED; # = map { $_ => 1 } qw(xover list_overview_fmt newnews xhdr);

my $EXPMAP; # fd -> [ idle_time, $self ]
my $EXPTIMER;
our $EXPTIME = 180; # 3 minutes
my $WEAKEN = {}; # string(nntpd) -> nntpd
my $WEAKTIMER;

sub update_idle_time ($) {
	my ($self) = @_;
	my $tmp = $self->{sock} or return;
	$tmp = fileno($tmp);
	defined $tmp and $EXPMAP->{$tmp} = [ now(), $self ];
}

# reduce FD pressure by closing some "git cat-file --batch" processes
# and unused FDs for msgmap and Xapian indices
sub weaken_groups () {
	$WEAKTIMER = undef;
	foreach my $nntpd (values %$WEAKEN) {
		$_->weaken_all foreach (@{$nntpd->{grouplist}});
	}
	$WEAKEN = {};
}

sub expire_old () {
	my $now = now();
	my $exp = $EXPTIME;
	my $old = $now - $exp;
	my $next = $now + $exp;
	my $nr = 0;
	my %new;
	while (my ($fd, $v) = each %$EXPMAP) {
		my ($idle_time, $nntp) = @$v;
		if ($idle_time < $old) {
			$nntp->close; # idempotent
		} else {
			my $nexp = $idle_time + $exp;
			$next = $nexp if ($nexp < $next);
			++$nr;
			$new{$fd} = $v;
		}
	}
	$EXPMAP = \%new;
	if ($nr) {
		$next -= $now;
		$next = 0 if $next < 0;
		$EXPTIMER = Danga::Socket->AddTimer($next, *expire_old);
		weaken_groups();
	} else {
		$EXPTIMER = undef;
		# noop to kick outselves out of the loop ASAP so descriptors
		# really get closed
		Danga::Socket->AddTimer(0, sub {});

		# grace period for reaping resources
		$WEAKTIMER ||= Danga::Socket->AddTimer(30, *weaken_groups);
	}
}

sub new ($$$) {
	my ($class, $sock, $nntpd) = @_;
	my $self = fields::new($class);
	binmode $sock, ':utf8'; # RFC 3977
	$self->SUPER::new($sock);
	$self->{nntpd} = $nntpd;
	res($self, '201 server ready - post via email');
	$self->{rbuf} = '';
	$self->watch_read(1);
	update_idle_time($self);
	$WEAKEN->{"$nntpd"} = $nntpd;
	$EXPTIMER ||= Danga::Socket->AddTimer($EXPTIME, *expire_old);
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
	my ($req, @args) = split(/\s+/, $l);
	$req = lc($req);
	$req = eval {
		no strict 'refs';
		$req = $DISABLED{$req} ? undef : *{'cmd_'.$req}{CODE};
	};
	return res($self, '500 command not recognized') unless $req;
	return res($self, r501) unless args_ok($req, scalar @args);

	my $res = eval { $req->($self, @args) };
	my $err = $@;
	if ($err && !$self->{closed}) {
		chomp($l = Dumper(\$l));
		err($self, 'error from: %s (%s)', $l, $err);
		$res = '503 program fault - command not performed';
	}
	return 0 unless defined $res;
	res($self, $res);
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
	do_more($self, $OVERVIEW_FMT);
}

sub list_headers ($;$) {
	my ($self) = @_;
	do_more($self, $LIST_HEADERS);
}

sub list_active ($;$) {
	my ($self, $wildmat) = @_;
	wildmat2re($wildmat);
	foreach my $ng (@{$self->{nntpd}->{grouplist}}) {
		$ng->{name} =~ $wildmat or next;
		group_line($self, $ng);
	}
}

sub list_active_times ($;$) {
	my ($self, $wildmat) = @_;
	wildmat2re($wildmat);
	foreach my $ng (@{$self->{nntpd}->{grouplist}}) {
		$ng->{name} =~ $wildmat or next;
		my $c = eval { $ng->mm->created_at } || time;
		more($self, "$ng->{name} $c $ng->{address}");
	}
}

sub list_newsgroups ($;$) {
	my ($self, $wildmat) = @_;
	wildmat2re($wildmat);
	foreach my $ng (@{$self->{nntpd}->{grouplist}}) {
		$ng->{name} =~ $wildmat or next;
		my $d = $ng->description;
		more($self, "$ng->{name} $d");
	}
}

# LIST SUBSCRIPTIONS, DISTRIB.PATS are not supported
sub cmd_list ($;$$) {
	my ($self, @args) = @_;
	if (scalar @args) {
		my $arg = shift @args;
		$arg =~ tr/A-Z./a-z_/;
		$arg = "list_$arg";
		return r501 if $DISABLED{$arg};

		$arg = eval {
			no strict 'refs';
			*{$arg}{CODE};
		};
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

sub cmd_listgroup ($;$) {
	my ($self, $group) = @_;
	if (defined $group) {
		my $res = cmd_group($self, $group);
		return $res if ($res !~ /\A211 /);
		more($self, $res);
	}

	$self->{ng} or return '412 no newsgroup selected';
	long_response($self, 0, long_response_limit, sub {
		my ($i) = @_;
		my $nr = $self->{ng}->mm->id_batch($$i, sub {
			my ($ary) = @_;
			more($self, join("\r\n", @$ary));
		});

		# -1 to adjust for implicit increment in long_response
		$$i = $nr ? $$i + $nr - 1 : long_response_limit;
	});
}

sub parse_time ($$;$) {
	my ($date, $time, $gmt) = @_;
	use Time::Local qw();
	my ($hh, $mm, $ss) = unpack('A2A2A2', $time);
	if (defined $gmt) {
		$gmt =~ /\A(?:UTC|GMT)\z/i or die "GM invalid: $gmt";
		$gmt = 1;
	}
	my @now = $gmt ? gmtime : localtime;
	my ($YYYY, $MM, $DD);
	if (length($date) == 8) { # RFC 3977 allows YYYYMMDD
		($YYYY, $MM, $DD) = unpack('A4A2A2', $date);
	} else { # legacy clients send YYMMDD
		($YYYY, $MM, $DD) = unpack('A2A2A2', $date);
		if ($YYYY > strftime('%y', @now)) {
			my $cur_year = $now[5] + 1900;
			$YYYY += int($cur_year / 1000) * 1000 - 100;
		}
	}
	if ($gmt) {
		Time::Local::timegm($ss, $mm, $hh, $DD, $MM - 1, $YYYY);
	} else {
		Time::Local::timelocal($ss, $mm, $hh, $DD, $MM - 1, $YYYY);
	}
}

sub group_line ($$) {
	my ($self, $ng) = @_;
	my ($min, $max) = $ng->mm->minmax;
	more($self, "$ng->{name} $max $min n") if defined $min && defined $max;
}

sub cmd_newgroups ($$$;$$) {
	my ($self, $date, $time, $gmt, $dists) = @_;
	my $ts = eval { parse_time($date, $time, $gmt) };
	return r501 if $@;

	# TODO dists
	more($self, '231 list of new newsgroups follows');
	foreach my $ng (@{$self->{nntpd}->{grouplist}}) {
		my $c = eval { $ng->mm->created_at } || 0;
		next unless $c > $ts;
		group_line($self, $ng);
	}
	'.'
}

sub wildmat2re (;$) {
	return $_[0] = qr/.*/ if (!defined $_[0] || $_[0] eq '*');
	my %keep;
	my $salt = rand;
	use Digest::SHA qw(sha1_hex);
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

sub cmd_newnews ($$$$;$$) {
	my ($self, $newsgroups, $date, $time, $gmt, $dists) = @_;
	my $ts = eval { parse_time($date, $time, $gmt) };
	return r501 if $@;
	more($self, '230 list of new articles by message-id follows');
	my ($keep, $skip) = split('!', $newsgroups, 2);
	ngpat2re($keep);
	ngpat2re($skip);
	my @srch;
	foreach my $ng (@{$self->{nntpd}->{grouplist}}) {
		$ng->{name} =~ $keep or next;
		$ng->{name} =~ $skip and next;
		my $srch = $ng->search or next;
		push @srch, $srch;
	};
	return '.' unless @srch;

	$ts .= '..';
	my $opts = { asc => 1, limit => 1000, offset => 0 };
	long_response($self, 0, long_response_limit, sub {
		my ($i) = @_;
		my $srch = $srch[0];
		my $res = $srch->query($ts, $opts);
		my $msgs = $res->{msgs};
		if (my $nr = scalar @$msgs) {
			more($self, '<' .
				join(">\r\n<", map { $_->mid } @$msgs ).
				'>');
			$opts->{offset} += $nr;
		} else {
			shift @srch;
			if (@srch) { # continue onto next newsgroup
				$opts->{offset} = 0;
			} else { # break out of the long response.
				$$i = long_response_limit;
			}
		}
	});
}

sub cmd_group ($$) {
	my ($self, $group) = @_;
	my $no_such = '411 no such news group';
	my $ng = $self->{nntpd}->{groups}->{$group} or return $no_such;

	$self->{ng} = $ng;
	my ($min, $max) = $ng->mm->minmax;
	$min ||= 0;
	$max ||= 0;
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
	$ng ? "440 mailto:$ng->{address} to post" : '440 posting not allowed'
}

sub cmd_quit ($) {
	my ($self) = @_;
	res($self, '205 closing connection - goodbye!');
	$self->close;
	undef;
}

sub art_lookup ($$$) {
	my ($self, $art, $set_headers) = @_;
	my $ng = $self->{ng};
	my ($n, $mid);
	my $err;
	if (defined $art) {
		if ($art =~ /\A\d+\z/o) {
			$err = '423 no such article number in this group';
			$n = int($art);
			goto find_mid;
		} elsif ($art =~ /\A<([^>]+)>\z/) {
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
	my $o = 'HEAD:' . mid2path($mid);
	my $bytes;
	my $s = eval { Email::MIME->new($ng->gcf->cat_file($o, \$bytes)) };
	return $err unless $s;
	my $lines;
	if ($set_headers) {
		$s->header_set('Newsgroups', $ng->{name});
		$s->header_set('Xref', xref($ng, $n));
		$lines = $s->body =~ tr!\n!\n!;

		# must be last
		$s->body_set('') if ($set_headers == 2);
	}
	[ $n, $mid, $s, $bytes, $lines, $ng ];
}

sub simple_body_write ($$) {
	my ($self, $s) = @_;
	my $body = $s->body;
	$s->body_set('');
	$body =~ s/^\./../smg;
	$body =~ s/(?<!\r)\n/\r\n/sg;
	do_more($self, $body);
	do_more($self, "\r\n") unless $body =~ /\r\n\z/s;
	'.'
}

sub set_art {
	my ($self, $art) = @_;
	$self->{article} = $art if defined $art && $art =~ /\A\d+\z/;
}

sub cmd_article ($;$) {
	my ($self, $art) = @_;
	my $r = art_lookup($self, $art, 1);
	return $r unless ref $r;
	my ($n, $mid, $s) = @$r;
	set_art($self, $art);
	more($self, "220 $n <$mid> article retrieved - head and body follow");
	do_more($self, $s->header_obj->as_string);
	do_more($self, "\r\n");
	simple_body_write($self, $s);
}

sub cmd_head ($;$) {
	my ($self, $art) = @_;
	my $r = art_lookup($self, $art, 2);
	return $r unless ref $r;
	my ($n, $mid, $s) = @$r;
	set_art($self, $art);
	more($self, "221 $n <$mid> article retrieved - head follows");
	do_more($self, $s->header_obj->as_string);
	'.'
}

sub cmd_body ($;$) {
	my ($self, $art) = @_;
	my $r = art_lookup($self, $art, 0);
	return $r unless ref $r;
	my ($n, $mid, $s) = @$r;
	set_art($self, $art);
	more($self, "222 $n <$mid> article retrieved - body follows");
	simple_body_write($self, $s);
}

sub cmd_stat ($;$) {
	my ($self, $art) = @_;
	my $r = art_lookup($self, $art, 0);
	return $r unless ref $r;
	my ($n, $mid, undef) = @$r;
	set_art($self, $art);
	"223 $n <$mid> article retrieved - request text separately";
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
	if ($range =~ /\A(\d+)\z/) {
		$beg = $end = $1;
	} elsif ($range =~ /\A(\d+)-\z/) {
		($beg, $end) = ($1, $max);
	} elsif ($range =~ /\A(\d+)-(\d+)\z/) {
		($beg, $end) = ($1, $2);
	} else {
		return r501;
	}
	$beg = $min if ($beg < $min);
	$end = $max if ($end > $max);
	return '420 No article(s) selected' if ($beg > $end);
	[ $beg, $end ];
}

sub long_response ($$$$) {
	my ($self, $beg, $end, $cb) = @_;
	die "BUG: nested long response" if $self->{long_res};

	my $fd = $self->{fd};
	defined $fd or return;
	# make sure we disable reading during a long response,
	# clients should not be sending us stuff and making us do more
	# work while we are stream a response to them
	$self->watch_read(0);
	my $t0 = now();
	$self->{long_res} = sub {
		# limit our own running time for fairness with other
		# clients and to avoid buffering too much:
		my $lim = 100;

		my $err;
		do {
			eval { $cb->(\$beg) };
		} until (($err = $@) || $self->{closed} ||
			 ++$beg > $end || !--$lim || $self->{write_buf_size});

		if ($err || $self->{closed}) {
			$self->{long_res} = undef;

			if ($err) {
				err($self,
				    "%s during long response[$fd] - %0.6f",
				    $err, now() - $t0);
			}
			if ($self->{closed}) {
				out($self, " deferred[$fd] aborted - %0.6f",
				           now() - $t0);
			} else {
				update_idle_time($self);
				$self->watch_read(1);
			}
		} elsif (!$lim || $self->{write_buf_size}) {
			# no recursion, schedule another call ASAP
			# but only after all pending writes are done
			update_idle_time($self);
			Danga::Socket->AddTimer(0, sub {
				$self->write($self->{long_res});
			});
		} else { # all done!
			$self->{long_res} = undef;
			$self->watch_read(1);
			res($self, '.');
			out($self, " deferred[$fd] done - %0.6f", now() - $t0);
		}
	};
	$self->{long_res}->(); # kick off!
	undef;
}

sub hdr_message_id ($$$) { # optimize XHDR Message-ID [range] for slrnpull.
	my ($self, $xhdr, $range) = @_;

	if (defined $range && $range =~ /\A<(.+)>\z/) { # Message-ID
		my ($ng, $n) = mid_lookup($self, $1);
		return r430 unless $n;
		hdr_mid_response($self, $xhdr, $ng, $n, $range, $range);
	} else { # numeric range
		$range = $self->{article} unless defined $range;
		my $r = get_range($self, $range);
		return $r unless ref $r;
		my $mm = $self->{ng}->mm;
		my ($beg, $end) = @$r;
		more($self, $xhdr ? r221 : r225);
		long_response($self, $beg, $end, sub {
			my ($i) = @_;
			my $mid = $mm->mid_for($$i);
			more($self, "$$i <$mid>") if defined $mid;
		});
	}
}

sub xref ($$) {
	my ($ng, $n) = @_;
	"$ng->{domain} $ng->{name}:$n"
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

sub hdr_xref ($$$) { # optimize XHDR Xref [range] for rtin
	my ($self, $xhdr, $range) = @_;

	if (defined $range && $range =~ /\A<(.+)>\z/) { # Message-ID
		my ($ng, $n) = mid_lookup($self, $1);
		return r430 unless $n;
		hdr_mid_response($self, $xhdr, $ng, $n, $range, xref($ng, $n));
	} else { # numeric range
		$range = $self->{article} unless defined $range;
		my $r = get_range($self, $range);
		return $r unless ref $r;
		my $ng = $self->{ng};
		my $mm = $ng->mm;
		my ($beg, $end) = @$r;
		more($self, $xhdr ? r221 : r225);
		long_response($self, $beg, $end, sub {
			my ($i) = @_;
			my $mid = $mm->mid_for($$i);
			more($self, "$$i ".xref($ng, $$i)) if defined $mid;
		});
	}
}

sub search_header_for {
	my ($srch, $mid, $field) = @_;
	my $smsg = $srch->lookup_message($mid) or return;
	$smsg = PublicInbox::SearchMsg->load_doc($smsg->{doc});
	$smsg->$field;
}

sub hdr_searchmsg ($$$$) {
	my ($self, $xhdr, $field, $range) = @_;
	if (defined $range && $range =~ /\A<(.+)>\z/) { # Message-ID
		my ($ng, $n) = mid_lookup($self, $1);
		return r430 unless $n;
		my $v = search_header_for($ng->search, $range, $field);
		hdr_mid_response($self, $xhdr, $ng, $n, $range, $v);
	} else { # numeric range
		$range = $self->{article} unless defined $range;
		my $srch = $self->{ng}->search;
		my $mm = $self->{ng}->mm;
		my $r = get_range($self, $range);
		return $r unless ref $r;
		my ($beg, $end) = @$r;
		more($self, $xhdr ? r221 : r225);
		my $off = 0;
		long_response($self, $beg, $end, sub {
			my ($i) = @_;
			my $res = $srch->query_xover($beg, $end, $off);
			my $msgs = $res->{msgs};
			my $nr = scalar @$msgs or return;
			$off += $nr;
			my $tmp = '';
			foreach my $s (@$msgs) {
				$tmp .= $s->num . ' ' . $s->$field . "\r\n";
			}
			do_more($self, $tmp);
			# -1 to adjust for implicit increment in long_response
			$$i = $nr ? $$i + $nr - 1 : long_response_limit;
		});
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
		hdr_searchmsg($self, $xhdr, $sub, $range);
	} elsif ($sub =~ /\A:(bytes|lines)\z/) {
		hdr_searchmsg($self, $xhdr, $1, $range);
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
	my ($self, $xhdr, $ng, $n, $mid, $v) = @_; # r: art_lookup result
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

sub cmd_xrover ($;$) {
	my ($self, $range) = @_;
	my $ng = $self->{ng} or return '412 no newsgroup selected';
	(defined $range && $range =~ /[<>]/) and
		return '420 No article(s) selected'; # no message IDs

	$range = $self->{article} unless defined $range;
	my $r = get_range($self, $range);
	return $r unless ref $r;
	my ($beg, $end) = @$r;
	my $mm = $ng->mm;
	my $srch = $ng->search;
	more($self, '224 Overview information follows');
	long_response($self, $beg, $end, sub {
		my ($i) = @_;
		my $mid = $mm->mid_for($$i) or return;
		my $h = search_header_for($srch, $mid, 'references');
		more($self, "$$i $h");
	});
}

sub over_line ($$) {
	my ($num, $smsg) = @_;
	# n.b. field access and procedural calls can be
	# 10%-15% faster than OO method calls:
	join("\t", $num,
		$smsg->{subject},
		$smsg->{from},
		PublicInbox::SearchMsg::date($smsg),
		'<'.PublicInbox::SearchMsg::mid($smsg).'>',
		$smsg->{references},
		PublicInbox::SearchMsg::bytes($smsg),
		PublicInbox::SearchMsg::lines($smsg));
}

sub cmd_over ($;$) {
	my ($self, $range) = @_;
	if ($range && $range =~ /\A<(.+)>\z/) {
		my ($ng, $n) = mid_lookup($self, $1);
		my $smsg = $ng->search->lookup_message($range) or
			return '430 No article with that message-id';
		more($self, '224 Overview information follows (multi-line)');
		$smsg = PublicInbox::SearchMsg->load_doc($smsg->{doc});

		# Only set article number column if it's the current group
		my $self_ng = $self->{ng};
		$n = 0 if (!$self_ng || $self_ng ne $ng);
		more($self, over_line($n, $smsg));
		'.';
	} else {
		cmd_xover($self, $range);
	}
}

sub cmd_xover ($;$) {
	my ($self, $range) = @_;
	$range = $self->{article} unless defined $range;
	my $r = get_range($self, $range);
	return $r unless ref $r;
	my ($beg, $end) = @$r;
	more($self, "224 Overview information follows for $beg to $end");
	my $srch = $self->{ng}->search;
	my $off = 0;
	long_response($self, $beg, $end, sub {
		my ($i) = @_;
		my $res = $srch->query_xover($beg, $end, $off);
		my $msgs = $res->{msgs};
		my $nr = scalar @$msgs or return;
		$off += $nr;

		# OVERVIEW.FMT
		more($self, join("\r\n", map {
			over_line(PublicInbox::SearchMsg::num($_), $_);
			} @$msgs));

		# -1 to adjust for implicit increment in long_response
		$$i = $nr ? $$i + $nr - 1 : long_response_limit;
	});
}

sub cmd_xpath ($$) {
	my ($self, $mid) = @_;
	return r501 unless $mid =~ /\A<(.+)>\z/;
	$mid = $1;
	my @paths;
	foreach my $ng (values %{$self->{nntpd}->{groups}}) {
		my $n = $ng->mm->num_for($mid);
		push @paths, "$ng->{name}/$n" if defined $n;
	}
	return '430 no such article on server' unless @paths;
	'223 '.join(' ', @paths);
}

sub res ($$) {
	my ($self, $line) = @_;
	do_write($self, $line . "\r\n");
}

sub more ($$) {
	my ($self, $line) = @_;
	do_more($self, $line . "\r\n");
}

sub do_write ($$) {
	my ($self, $data) = @_;
	my $done = $self->write($data);
	die if $self->{closed};

	# Do not watch for readability if we have data in the queue,
	# instead re-enable watching for readability when we can
	$self->watch_read(0) if (!$done || $self->{long_res});

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

use constant MSG_MORE => ($^O eq 'linux') ? 0x8000 : 0;

sub do_more ($$) {
	my ($self, $data) = @_;
	if (MSG_MORE && !$self->{write_buf_size}) {
		my $n = send($self->{sock}, $data, MSG_MORE);
		if (defined $n) {
			my $dlen = length($data);
			return 1 if $n == $dlen; # all done!
			$data = substr($data, $n, $dlen - $n);
		}
	}
	do_write($self, $data);
}

# callbacks for Danga::Socket

sub event_hup { $_[0]->close }
sub event_err { $_[0]->close }

sub event_write {
	my ($self) = @_;
	update_idle_time($self);
	# only continue watching for readability when we are done writing:
	if ($self->write(undef) == 1 && !$self->{long_res}) {
		$self->watch_read(1);
	}
}

sub event_read {
	my ($self) = @_;
	use constant LINE_MAX => 512; # RFC 977 section 2.3
	my $r = 1;

	my $buf = $self->read(LINE_MAX) or return $self->close;
	$self->{rbuf} .= $$buf;
	while ($r > 0 && $self->{rbuf} =~ s/\A\s*([^\r\n]+)\r?\n//) {
		my $line = $1;
		my $t0 = now();
		my $fd = $self->{fd};
		$r = eval { process_line($self, $line) };
		my $d = $self->{long_res} ?
			" deferred[$fd]" : '';
		out($self, "[$fd] %s - %0.6f$d", $line, now() - $t0);
	}

	return $self->close if $r < 0;
	my $len = length($self->{rbuf});
	return $self->close if ($len >= LINE_MAX);
	update_idle_time($self);
}

sub watch_read {
	my ($self, $bool) = @_;
	my $rv = $self->SUPER::watch_read($bool);
	if ($bool && $self->{rbuf} ne '') {
		# Force another read if there is a pipelined request.
		# We don't know if the socket has anything for us to read,
		# and we must double-check again by the time the timer fires
		# in case we really did dispatch a read event and started
		# another long response.
		Danga::Socket->AddTimer(0, sub {
			if (&Danga::Socket::POLLIN & $self->{event_watch}) {
				event_read($self);
			}
		});
	}
	$rv;
}

# for graceful shutdown in PublicInbox::Daemon:
sub busy () {
	my ($self) = @_;
	($self->{rbuf} ne '' || $self->{long_res} || $self->{write_buf_size});
}

1;
