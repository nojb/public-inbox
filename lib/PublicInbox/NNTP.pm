# Copyright (C) 2015-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Each instance of this represents a NNTP client socket
package PublicInbox::NNTP;
use strict;
use warnings;
use base qw(PublicInbox::DS);
use fields qw(nntpd article rbuf ng);
use PublicInbox::Search;
use PublicInbox::Msgmap;
use PublicInbox::MID qw(mid_escape);
use PublicInbox::Git;
require PublicInbox::EvCleanup;
use Email::Simple;
use POSIX qw(strftime);
PublicInbox::DS->import(qw(now msg_more));
use Digest::SHA qw(sha1_hex);
use Time::Local qw(timegm timelocal);
use constant {
	r501 => '501 command syntax error',
	r221 => '221 Header follows',
	r224 => '224 Overview information follows (multi-line)',
	r225 =>	'225 Headers follow (multi-line)',
	r430 => '430 No article with that message-id',
};
use PublicInbox::Syscall qw(EPOLLIN EPOLLONESHOT);
use Errno qw(EAGAIN);

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
	event_step($_) for @$q;
}

sub requeue ($) {
	push @$nextq, $_[0];
	$nextt ||= PublicInbox::EvCleanup::asap(*next_tick);
}

sub update_idle_time ($) {
	my ($self) = @_;
	my $sock = $self->{sock} or return;
	$EXPMAP->{fileno($sock)} = [ now(), $self ];
}

sub expire_old () {
	my $now = now();
	my $exp = $EXPTIME;
	my $old = $now - $exp;
	my $nr = 0;
	my $closed = 0;
	my %new;
	while (my ($fd, $v) = each %$EXPMAP) {
		my ($idle_time, $nntp) = @$v;
		if ($idle_time < $old) {
			if ($nntp->shutdn) {
				$closed++;
			} else {
				++$nr;
				$new{$fd} = $v;
			}
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
		PublicInbox::EvCleanup::asap(sub {}) if $closed;
	}
}

sub greet ($) { $_[0]->write($_[0]->{nntpd}->{greet}) };

sub new ($$$) {
	my ($class, $sock, $nntpd) = @_;
	my $self = fields::new($class);
	my $ev = EPOLLIN;
	my $wbuf;
	if (ref($sock) eq 'IO::Socket::SSL' && !$sock->accept_SSL) {
		$ev = PublicInbox::TLS::epollbit() or return CORE::close($sock);
		$wbuf = [ \&PublicInbox::DS::accept_tls_step, \&greet ];
	}
	$self->SUPER::new($sock, $ev | EPOLLONESHOT);
	$self->{nntpd} = $nntpd;
	if ($wbuf) {
		$self->{wbuf} = $wbuf;
	} else {
		greet($self);
	}
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
	if ($err && $self->{sock}) {
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
	msg_more($self, $OVERVIEW_FMT);
}

sub list_headers ($;$) {
	my ($self) = @_;
	msg_more($self, $LIST_HEADERS);
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
	if (bytes::length($date) == 8) { # RFC 3977 allows YYYYMMDD
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
	$self->shutdn;
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

	# why? leafnode requires a Path: header for some inexplicable
	# reason.  We'll fake the shortest one possible.
	$hdr->header_set('Path', 'y');

	# leafnode (and maybe other NNTP clients) have trouble dealing
	# with v2 messages which have multiple Message-IDs (either due
	# to our own content-based dedupe or buggy git-send-email versions).
	my @mids = $hdr->header('Message-ID');
	if (scalar(@mids) > 1) {
		my $mid0 = "<$mid>";
		$hdr->header_set('Message-ID', $mid0);
		my @alt = $hdr->header('X-Alt-Message-ID');
		my %seen = map { $_ => 1 } (@alt, $mid0);
		foreach my $m (@mids) {
			next if $seen{$m}++;
			push @alt, $m;
		}
		$hdr->header_set('X-Alt-Message-ID', @alt);
	}

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

	# Email::Simple->new will modify $msg in-place as documented
	# in its manpage, so what's left is the body and we won't need
	# to call Email::Simple::body(), later
	my $hdr = Email::Simple->new($msg)->header_obj;
	set_nntp_headers($self, $hdr, $ng, $n, $mid) if $set_headers;
	[ $n, $mid, $msg, $hdr ];
}

sub msg_body_write ($$) {
	my ($self, $msg) = @_;

	# these can momentarily double the memory consumption :<
	$$msg =~ s/^\./../smg;
	$$msg =~ s/(?<!\r)\n/\r\n/sg; # Alpine barfs without this
	$$msg .= "\r\n" unless $$msg =~ /\r\n\z/s;
	msg_more($self, $$msg);
	'.'
}

sub set_art {
	my ($self, $art) = @_;
	$self->{article} = $art if defined $art && $art =~ /\A[0-9]+\z/;
}

sub msg_hdr_write ($$$) {
	my ($self, $hdr, $body_follows) = @_;
	$hdr = $hdr->as_string;
	utf8::encode($hdr);
	$hdr =~ s/(?<!\r)\n/\r\n/sg; # Alpine barfs without this

	# for leafnode compatibility, we need to ensure Message-ID headers
	# are only a single line.  We can't subclass Email::Simple::Header
	# and override _default_fold_at in here, either; since that won't
	# affect messages already in the archive.
	$hdr =~ s/^(Message-ID:)[ \t]*\r\n[ \t]+([^\r]+)\r\n/$1 $2\r\n/igsm;
	$hdr .= "\r\n" if $body_follows;
	msg_more($self, $hdr);
}

sub cmd_article ($;$) {
	my ($self, $art) = @_;
	my $r = art_lookup($self, $art, 1);
	return $r unless ref $r;
	my ($n, $mid, $msg, $hdr) = @$r;
	set_art($self, $art);
	more($self, "220 $n <$mid> article retrieved - head and body follow");
	msg_hdr_write($self, $hdr, 1);
	msg_body_write($self, $msg);
}

sub cmd_head ($;$) {
	my ($self, $art) = @_;
	my $r = art_lookup($self, $art, 2);
	return $r unless ref $r;
	my ($n, $mid, undef, $hdr) = @$r;
	set_art($self, $art);
	more($self, "221 $n <$mid> article retrieved - head follows");
	msg_hdr_write($self, $hdr, 0);
	'.'
}

sub cmd_body ($;$) {
	my ($self, $art) = @_;
	my $r = art_lookup($self, $art, 0);
	return $r unless ref $r;
	my ($n, $mid, $msg) = @$r;
	set_art($self, $art);
	more($self, "222 $n <$mid> article retrieved - body follows");
	msg_body_write($self, $msg);
}

sub cmd_stat ($;$) {
	my ($self, $art) = @_;
	my $r = art_lookup($self, $art, 0);
	return $r unless ref $r;
	my ($n, $mid) = @$r;
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
	my ($self, $cb) = @_; # cb returns true if more, false if done

	my $fd = fileno($self->{sock});
	defined $fd or return;
	# make sure we disable reading during a long response,
	# clients should not be sending us stuff and making us do more
	# work while we are stream a response to them
	my $t0 = now();
	my $long_cb; # DANGER: self-referential
	$long_cb = sub {
		# wbuf is unset or empty, here; $cb may add to it
		my $more = eval { $cb->() };
		if ($@ || !$self->{sock}) { # something bad happened...
			$long_cb = undef;
			my $diff = now() - $t0;
			if ($@) {
				err($self,
				    "%s during long response[$fd] - %0.6f",
				    $@, $diff);
			}
			out($self, " deferred[$fd] aborted - %0.6f", $diff);
			$self->close;
		} elsif ($more) { # $self->{wbuf}:
			update_idle_time($self);

			# no recursion, schedule another call ASAP
			# but only after all pending writes are done
			my $wbuf = $self->{wbuf} ||= [];
			push @$wbuf, $long_cb;

			# wbuf may be populated by $cb, no need to rearm if so:
			requeue($self) if scalar(@$wbuf) == 1;
		} else { # all done!
			$long_cb = undef;
			res($self, '.');
			out($self, " deferred[$fd] done - %0.6f", now() - $t0);
			requeue($self) unless $self->{wbuf};
		}
	};
	$self->write($long_cb); # kick off!
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
			msg_more($self, $tmp);
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

sub cmd_starttls ($) {
	my ($self) = @_;
	my $sock = $self->{sock} or return;
	# RFC 4642 2.2.1
	(ref($sock) eq 'IO::Socket::SSL') and return '502 Command unavailable';
	my $opt = $self->{nntpd}->{accept_tls} or
		return '580 can not initiate TLS negotiation';
	res($self, '382 Continue with TLS negotiation');
	$self->{sock} = IO::Socket::SSL->start_SSL($sock, %$opt);
	requeue($self) if PublicInbox::DS::accept_tls_step($self);
	undef;
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

sub res ($$) { do_write($_[0], $_[1] . "\r\n") }

sub more ($$) { msg_more($_[0], $_[1] . "\r\n") }

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

	return unless $self->flush_write && $self->{sock};

	update_idle_time($self);
	# only read more requests if we've drained the write buffer,
	# otherwise we can be buffering infinitely w/o backpressure

	use constant LINE_MAX => 512; # RFC 977 section 2.3
	my $rbuf = $self->{rbuf} // (\(my $x = ''));
	my $r = 1;

	if (index($$rbuf, "\n") < 0) {
		my $off = bytes::length($$rbuf);
		$r = $self->do_read($rbuf, LINE_MAX, $off) or return;
	}
	while ($r > 0 && $$rbuf =~ s/\A[ \t\r\n]*([^\r\n]*)\r?\n//) {
		my $line = $1;
		return $self->close if $line =~ /[[:cntrl:]]/s;
		my $t0 = now();
		my $fd = fileno($self->{sock});
		$r = eval { process_line($self, $line) };
		my $pending = $self->{wbuf} ? ' pending' : '';
		out($self, "[$fd] %s - %0.6f$pending", $line, now() - $t0);
	}

	return $self->close if $r < 0;
	my $len = bytes::length($$rbuf);
	return $self->close if ($len >= LINE_MAX);
	if ($len) {
		$self->{rbuf} = $rbuf;
	} else {
		delete $self->{rbuf};
	}
	update_idle_time($self);

	# maybe there's more pipelined data, or we'll have
	# to register it for socket-readiness notifications
	requeue($self) unless $self->{wbuf};
}

sub not_idle_long ($$) {
	my ($self, $now) = @_;
	my $sock = $self->{sock} or return;
	my $ary = $EXPMAP->{fileno($sock)} or return;
	my $exp_at = $ary->[0] + $EXPTIME;
	$exp_at > $now;
}

# for graceful shutdown in PublicInbox::Daemon:
sub busy {
	my ($self, $now) = @_;
	($self->{rbuf} || $self->{wbuf} || not_idle_long($self, $now));
}

1;
