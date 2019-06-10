# Copyright (C) 2015-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Each instance of this represents a NNTP client socket
package PublicInbox::NNTP;
use strict;
use warnings;
use base qw(PublicInbox::DS);
use fields qw(nntpd article rbuf ng long_res);
use PublicInbox::Search;
use PublicInbox::Msgmap;
use PublicInbox::MID qw(mid_escape);
use PublicInbox::Git;
require PublicInbox::EvCleanup;
use Email::Simple;
use POSIX qw(strftime);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
use Digest::SHA qw(sha1_hex);
use Time::Local qw(timegm timelocal);
use constant {
	r501 => '501 command syntax error',
	r221 => '221 Header follows',
	r224 => '224 Overview information follows (multi-line)',
	r225 =>	'225 Headers follow (multi-line)',
	r430 => '430 No article with that message-id',
};

sub now () { clock_gettime(CLOCK_MONOTONIC) };

my @OVERVIEW = qw(Subject From Date Message-ID References Xref);
my $OVERVIEW_FMT = join(":\r\n", @OVERVIEW, qw(Bytes Lines)) . ":\r\n";
my $LIST_HEADERS = join("\r\n", @OVERVIEW,
			qw(:bytes :lines Xref To Cc)) . "\r\n";

# disable commands with easy DoS potential:
my %DISABLED; # = map { $_ => 1 } qw(xover list_overview_fmt newnews xhdr);

my $EXPMAP; # fd -> [ idle_time, $self ]
my $expt;
our $EXPTIME = 180; # 3 minutes
my $nextt;

my $nextq = [];
sub next_tick () {
	$nextt = undef;
	my $q = $nextq;
	$nextq = [];
	foreach my $nntp (@$q) {
		# for request && response protocols, always finish writing
		# before finishing reading:
		if (my $long_cb = $nntp->{long_res}) {
			$nntp->write($long_cb);
		} else {
			# pipelined request, we bypassed socket-readiness
			# checks to get here:
			event_read($nntp);

			# maybe there's more pipelined data, or we'll have
			# to register it for socket-readiness notifications
			if (!$nntp->{long_res} && !$nntp->{closed}) {
				check_read($nntp);
			}
		}
	}
}

sub update_idle_time ($) {
	my ($self) = @_;
        my $sock = $self->{sock} or return;
	my $fd = fileno($sock);
	defined $fd and $EXPMAP->{$fd} = [ now(), $self ];
}

sub expire_old () {
	my $now = now();
	my $exp = $EXPTIME;
	my $old = $now - $exp;
	my $nr = 0;
	my %new;
	while (my ($fd, $v) = each %$EXPMAP) {
		my ($idle_time, $nntp) = @$v;
		if ($idle_time < $old) {
			$nntp->close; # idempotent
		} else {
			++$nr;
			$new{$fd} = $v;
		}
	}
	$EXPMAP = \%new;
	if ($nr) {
		$expt = PublicInbox::EvCleanup::later(*expire_old);
	} else {
		$expt = undef;
		# noop to kick outselves out of the loop ASAP so descriptors
		# really get closed
		PublicInbox::EvCleanup::asap(sub {});
	}
}

sub new ($$$) {
	my ($class, $sock, $nntpd) = @_;
	my $self = fields::new($class);
	$self->SUPER::new($sock);
	$self->{nntpd} = $nntpd;
	res($self, '201 ' . $nntpd->{servername} . ' ready - post via email');
	$self->{rbuf} = '';
	$self->watch_read(1);
	update_idle_time($self);
	$expt ||= PublicInbox::EvCleanup::later(*expire_old);
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
	my ($req, @args) = split(/[ \t]/, $l);
	return 1 unless defined($req); # skip blank line
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
		local $/ = "\n";
		chomp($l);
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
		$ng->{newsgroup} =~ $wildmat or next;
		group_line($self, $ng);
	}
}

sub list_active_times ($;$) {
	my ($self, $wildmat) = @_;
	wildmat2re($wildmat);
	foreach my $ng (@{$self->{nntpd}->{grouplist}}) {
		$ng->{newsgroup} =~ $wildmat or next;
		my $c = eval { $ng->mm->created_at } || time;
		more($self, "$ng->{newsgroup} $c $ng->{-primary_address}");
	}
}

sub list_newsgroups ($;$) {
	my ($self, $wildmat) = @_;
	wildmat2re($wildmat);
	foreach my $ng (@{$self->{nntpd}->{grouplist}}) {
		$ng->{newsgroup} =~ $wildmat or next;
		my $d = $ng->description;
		more($self, "$ng->{newsgroup} $d");
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
	my $n = 0;
	long_response($self, sub {
		my $ary = $self->{ng}->mm->ids_after(\$n);
		scalar @$ary or return;
		more($self, join("\r\n", @$ary));
		1;
	});
}

sub parse_time ($$;$) {
	my ($date, $time, $gmt) = @_;
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
		my $cur_year = $now[5] + 1900;
		if ($YYYY > $cur_year) {
			$YYYY += int($cur_year / 1000) * 1000 - 100;
		}
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
	more($self, "$ng->{newsgroup} $max $min n") if defined $min && defined $max;
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
	my @over;
	foreach my $ng (@{$self->{nntpd}->{grouplist}}) {
		$ng->{newsgroup} =~ $keep or next;
		$ng->{newsgroup} =~ $skip and next;
		my $over = $ng->over or next;
		push @over, $over;
	};
	return '.' unless @over;

	my $prev = 0;
	long_response($self, sub {
		my $over = $over[0];
		my $msgs = $over->query_ts($ts, $prev);
		if (scalar @$msgs) {
			more($self, '<' .
				join(">\r\n<", map { $_->mid } @$msgs ).
				'>');
			$prev = $msgs->[-1]->{num};
		} else {
			shift @over;
			if (@over) { # continue onto next newsgroup
				$prev = 0;
				return 1;
			} else { # break out of the long response.
				return;
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
	$ng ? "440 mailto:$ng->{-primary_address} to post"
		: '440 posting not allowed'
}

sub cmd_quit ($) {
	my ($self) = @_;
	res($self, '205 closing connection - goodbye!');
	$self->close;
	undef;
}

sub header_append ($$$) {
	my ($hdr, $k, $v) = @_;
	my @v = $hdr->header($k);
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

sub set_nntp_headers ($$$$$) {
	my ($self, $hdr, $ng, $n, $mid) = @_;

	# clobber some
	my $xref = xref($self, $ng, $n, $mid);
	$hdr->header_set('Xref', $xref);
	$xref =~ s/:[0-9]+//g;
	$hdr->header_set('Newsgroups', (split(/ /, $xref, 2))[1]);
	header_append($hdr, 'List-Post', "<mailto:$ng->{-primary_address}>");
	if (my $url = $ng->base_url) {
		$mid = mid_escape($mid);
		header_append($hdr, 'Archived-At', "<$url$mid/>");
		header_append($hdr, 'List-Archive', "<$url>");
	}
}

sub art_lookup ($$$) {
	my ($self, $art, $set_headers) = @_;
	my $ng = $self->{ng};
	my ($n, $mid);
	my $err;
	if (defined $art) {
		if ($art =~ /\A[0-9]+\z/) {
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
	my $smsg = $ng->over->get_art($n) or return $err;
	my $msg = $ng->msg_by_smsg($smsg) or return $err;
	my $s = Email::Simple->new($msg);
	if ($set_headers) {
		set_nntp_headers($self, $s->header_obj, $ng, $n, $mid);

		# must be last
		$s->body_set('') if ($set_headers == 2);
	}
	[ $n, $mid, $s, $smsg->bytes, $smsg->lines, $ng ];
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
	$self->{article} = $art if defined $art && $art =~ /\A[0-9]+\z/;
}

sub _header ($) {
	my $hdr = $_[0]->header_obj->as_string;
	utf8::encode($hdr);
	$hdr =~ s/(?<!\r)\n/\r\n/sg;
	$hdr
}

sub cmd_article ($;$) {
	my ($self, $art) = @_;
	my $r = art_lookup($self, $art, 1);
	return $r unless ref $r;
	my ($n, $mid, $s) = @$r;
	set_art($self, $art);
	more($self, "220 $n <$mid> article retrieved - head and body follow");
	do_more($self, _header($s));
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
	do_more($self, _header($s));
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
	[ $beg, $end ];
}

sub long_response ($$) {
	my ($self, $cb) = @_;
	die "BUG: nested long response" if $self->{long_res};

	my $fd = fileno($self->{sock});
	defined $fd or return;
	# make sure we disable reading during a long response,
	# clients should not be sending us stuff and making us do more
	# work while we are stream a response to them
	$self->watch_read(0);
	my $t0 = now();
	$self->{long_res} = sub {
		my $more = eval { $cb->() };
		if ($@ || $self->{closed}) {
			$self->{long_res} = undef;

			if ($@) {
				err($self,
				    "%s during long response[$fd] - %0.6f",
				    $@, now() - $t0);
			}
			if ($self->{closed}) {
				out($self, " deferred[$fd] aborted - %0.6f",
				           now() - $t0);
			} else {
				update_idle_time($self);
				check_read($self);
			}
		} elsif ($more) { # scalar @{$self->{wbuf}}:
			# no recursion, schedule another call ASAP
			# but only after all pending writes are done
			update_idle_time($self);

			push @$nextq, $self;
			$nextt ||= PublicInbox::EvCleanup::asap(*next_tick);
		} else { # all done!
			$self->{long_res} = undef;
			check_read($self);
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
		long_response($self, sub {
			my $r = $mm->msg_range(\$beg, $end);
			@$r or return;
			more($self, join("\r\n", map {
				"$_->[0] <$_->[1]>"
			} @$r));
			1;
		});
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

sub hdr_xref ($$$) { # optimize XHDR Xref [range] for rtin
	my ($self, $xhdr, $range) = @_;

	if (defined $range && $range =~ /\A<(.+)>\z/) { # Message-ID
		my $mid = $1;
		my ($ng, $n) = mid_lookup($self, $mid);
		return r430 unless $n;
		hdr_mid_response($self, $xhdr, $ng, $n, $range,
				xref($self, $ng, $n, $mid));
	} else { # numeric range
		$range = $self->{article} unless defined $range;
		my $r = get_range($self, $range);
		return $r unless ref $r;
		my $ng = $self->{ng};
		my $mm = $ng->mm;
		my ($beg, $end) = @$r;
		more($self, $xhdr ? r221 : r225);
		long_response($self, sub {
			my $r = $mm->msg_range(\$beg, $end);
			@$r or return;
			more($self, join("\r\n", map {
				my $num = $_->[0];
				"$num ".xref($self, $ng, $num, $_->[1]);
			} @$r));
			1;
		});
	}
}

sub over_header_for {
	my ($over, $num, $field) = @_;
	my $smsg = $over->get_art($num) or return;
	return PublicInbox::SearchMsg::date($smsg) if $field eq 'date';
	$smsg->{$field};
}

sub hdr_searchmsg ($$$$) {
	my ($self, $xhdr, $field, $range) = @_;
	if (defined $range && $range =~ /\A<(.+)>\z/) { # Message-ID
		my ($ng, $n) = mid_lookup($self, $1);
		return r430 unless defined $n;
		my $v = over_header_for($ng->over, $n, $field);
		hdr_mid_response($self, $xhdr, $ng, $n, $range, $v);
	} else { # numeric range
		$range = $self->{article} unless defined $range;
		my $over = $self->{ng}->over;
		my $mm = $self->{ng}->mm;
		my $r = get_range($self, $range);
		return $r unless ref $r;
		my ($beg, $end) = @$r;
		more($self, $xhdr ? r221 : r225);
		my $cur = $beg;
		long_response($self, sub {
			my $msgs = $over->query_xover($cur, $end);
			my $nr = scalar @$msgs or return;
			my $tmp = '';
			foreach my $s (@$msgs) {
				$tmp .= $s->{num} . ' ' . $s->$field . "\r\n";
			}
			utf8::encode($tmp);
			do_more($self, $tmp);
			$cur = $msgs->[-1]->{num} + 1;
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
	my $over = $ng->over;
	more($self, '224 Overview information follows');

	long_response($self, sub {
		my $h = over_header_for($over, $beg, 'references');
		more($self, "$beg $h") if defined($h);
		$beg++ < $end;
	});
}

sub over_line ($$$$) {
	my ($self, $ng, $num, $smsg) = @_;
	# n.b. field access and procedural calls can be
	# 10%-15% faster than OO method calls:
	my $s = join("\t", $num,
		$smsg->{subject},
		$smsg->{from},
		PublicInbox::SearchMsg::date($smsg),
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
	if ($range && $range =~ /\A<(.+)>\z/) {
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

sub cmd_xover ($;$) {
	my ($self, $range) = @_;
	$range = $self->{article} unless defined $range;
	my $r = get_range($self, $range);
	return $r unless ref $r;
	my ($beg, $end) = @$r;
	more($self, "224 Overview information follows for $beg to $end");
	my $over = $self->{ng}->over;
	my $cur = $beg;
	long_response($self, sub {
		my $msgs = $over->query_xover($cur, $end);
		my $nr = scalar @$msgs or return;

		# OVERVIEW.FMT
		more($self, join("\r\n", map {
			over_line($self, $self->{ng}, $_->{num}, $_);
			} @$msgs));
		$cur = $msgs->[-1]->{num} + 1;
	});
}

sub cmd_xpath ($$) {
	my ($self, $mid) = @_;
	return r501 unless $mid =~ /\A<(.+)>\z/;
	$mid = $1;
	my @paths;
	foreach my $ng (values %{$self->{nntpd}->{groups}}) {
		my $n = $ng->mm->num_for($mid);
		push @paths, "$ng->{newsgroup}/$n" if defined $n;
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
	return 0 if $self->{closed};

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
	if (MSG_MORE && !scalar(@{$self->{wbuf}})) {
		my $n = send($self->{sock}, $data, MSG_MORE);
		if (defined $n) {
			my $dlen = length($data);
			return 1 if $n == $dlen; # all done!
			$data = substr($data, $n, $dlen - $n);
		}
	}
	do_write($self, $data);
}

# callbacks for PublicInbox::DS

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

	if (index($self->{rbuf}, "\n") < 0) {
		my $buf = $self->read(LINE_MAX) or return $self->close;
		$self->{rbuf} .= $$buf;
	}
	my $r = 1;
	while ($r > 0 && $self->{rbuf} =~ s/\A[ \t\r\n]*([^\r\n]*)\r?\n//) {
		my $line = $1;
		return $self->close if $line =~ /[[:cntrl:]]/s;
		my $t0 = now();
		my $fd = fileno($self->{sock});
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

sub check_read {
	my ($self) = @_;
	if (index($self->{rbuf}, "\n") >= 0) {
		# Force another read if there is a pipelined request.
		# We don't know if the socket has anything for us to read,
		# and we must double-check again by the time the timer fires
		# in case we really did dispatch a read event and started
		# another long response.
		push @$nextq, $self;
		$nextt ||= PublicInbox::EvCleanup::asap(*next_tick);
	} else {
		# no pipelined requests available, let the kernel know
		# to wake us up if there's more
		$self->watch_read(1); # PublicInbox::DS::watch_read
	}
}

sub not_idle_long ($$) {
	my ($self, $now) = @_;
        my $sock = $self->{sock} or return;
	defined(my $fd = fileno($sock)) or return;
	my $ary = $EXPMAP->{$fd} or return;
	my $exp_at = $ary->[0] + $EXPTIME;
	$exp_at > $now;
}

# for graceful shutdown in PublicInbox::Daemon:
sub busy {
	my ($self, $now) = @_;
	($self->{rbuf} ne '' || $self->{long_res} ||
		scalar(@{$self->{wbuf}}) || not_idle_long($self, $now));
}

1;
