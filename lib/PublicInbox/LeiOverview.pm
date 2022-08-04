# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# per-mitem/smsg iterators for search results
# "ovv" => "Overview viewer"
package PublicInbox::LeiOverview;
use strict;
use v5.10.1;
use parent qw(PublicInbox::Lock);
use POSIX qw(strftime);
use Fcntl qw(F_GETFL O_APPEND);
use File::Spec;
use File::Temp ();
use PublicInbox::MID qw($MID_EXTRACT);
use PublicInbox::Address qw(pairs);
use PublicInbox::Config;
use PublicInbox::Search qw(get_pct);
use PublicInbox::LeiDedupe;
use PublicInbox::LeiToMail;

# cf. https://en.wikipedia.org/wiki/JSON_streaming
my $JSONL = 'ldjson|ndjson|jsonl'; # 3 names for the same thing

sub iso8601 ($) { strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($_[0])) }

# we open this in the parent process before ->wq_io_do handoff
sub ovv_out_lk_init ($) {
	my ($self) = @_;
	my $tmp = File::Temp->new("lei-ovv.dst.$$.lock-XXXX",
					TMPDIR => 1, UNLINK => 0);
	$self->{"lk_id.$self.$$"} = $self->{lock_path} = $tmp->filename;
}

sub ovv_out_lk_cancel ($) {
	my ($self) = @_;
	my $lock_path = delete $self->{"lk_id.$self.$$"} or return;
	unlink($lock_path);
}

sub detect_fmt ($) {
	my ($dst) = @_;
	if ($dst =~ m!\A([:/]+://)!) {
		die "$1 support not implemented, yet\n";
	} elsif (!-e $dst || -d _) {
		'maildir'; # the default TODO: MH?
	} elsif (-f _ || -p _) {
		die "unable to determine mbox family of $dst\n";
	} else {
		die "unable to determine format of $dst\n";
	}
}

sub new {
	my ($class, $lei, $ofmt_key) = @_;
	my $opt = $lei->{opt};
	my $dst = $opt->{output} // '-';
	$dst = '/dev/stdout' if $dst eq '-';
	$ofmt_key //= 'format';

	my $fmt = $opt->{$ofmt_key};
	$fmt = lc($fmt) if defined $fmt;
	if ($dst =~ m!\A([a-z0-9\+]+)://!is) {
		defined($fmt) and die <<"";
--$ofmt_key=$fmt invalid with URL $dst

		$fmt = lc $1;
	} elsif ($dst =~ s/\A([a-z0-9]+)://is) { # e.g. Maildir:/home/user/Mail/
		my $ofmt = lc $1;
		$fmt //= $ofmt;
		die <<"" if $fmt ne $ofmt;
--$ofmt_key=$fmt and --output=$ofmt conflict

	}
	my $devfd = $lei->path_to_fd($dst) // return;
	$fmt //= $devfd >= 0 ? 'json' : detect_fmt($dst);

	if (index($dst, '://') < 0) { # not a URL, so assume path
		 $dst = $lei->canonpath_harder($dst);
	} # else URL

	my $self = bless { fmt => $fmt, dst => $dst }, $class;
	$lei->{ovv} = $self;
	my $json;
	if ($fmt =~ /\A($JSONL|(?:concat)?json)\z/) {
		$json = $self->{json} = ref(PublicInbox::Config->json);
	}
	if ($devfd >= 0) {
		my $isatty = $lei->{need_pager} = -t $lei->{$devfd};
		$opt->{pretty} //= $isatty;
		if (!$isatty && -f _) {
			my $fl = fcntl($lei->{$devfd}, F_GETFL, 0) //
					die("fcntl(/dev/fd/$devfd): $!\n");
			ovv_out_lk_init($self) unless ($fl & O_APPEND);
		} else {
			ovv_out_lk_init($self);
		}
	} elsif (!$opt->{quiet}) {
		$lei->{-progress} = 1;
	}
	if ($json) {
		$lei->{dedupe} //= PublicInbox::LeiDedupe->new($lei);
	} else {
		$lei->{l2m} = PublicInbox::LeiToMail->new($lei);
		if ($opt->{mua} && $lei->{l2m}->lock_free) {
			$lei->{early_mua} = 1;
			$opt->{alert} //= [ ':WINCH,:bell' ] if -t $lei->{1};
		}
	}
	die("--shared is only for v2 inbox output\n") if
		$self->{fmt} ne 'v2' && $lei->{opt}->{shared};
	$self;
}

# called once by parent
sub ovv_begin {
	my ($self, $lei) = @_;
	if ($self->{fmt} eq 'json') {
		$lei->out('[');
	} # TODO HTML/Atom/...
}

# called once by parent (via PublicInbox::PktOp  '' => query_done)
sub ovv_end {
	my ($self, $lei) = @_;
	if ($self->{fmt} eq 'json') {
		# JSON doesn't allow trailing commas, and preventing
		# trailing commas is a PITA when parallelizing outputs
		$lei->out("null]\n");
	} elsif ($self->{fmt} eq 'concatjson') {
		$lei->out("\n");
	}
}

# prepares an smsg for JSON
sub _unbless_smsg {
	my ($smsg, $mitem) = @_;

	# TODO: make configurable
	# num/tid are nonsensical with multi-inbox search,
	# lines/bytes are not generally useful
	delete @$smsg{qw(num tid lines bytes)};
	$smsg->{rt} = iso8601(delete $smsg->{ts}); # JMAP receivedAt
	$smsg->{dt} = iso8601(delete $smsg->{ds}); # JMAP UTCDate
	$smsg->{pct} = get_pct($mitem) if $mitem;
	if (my $r = delete $smsg->{references}) {
		@{$smsg->{refs}} = ($r =~ m/$MID_EXTRACT/go);
	}
	if (my $m = delete($smsg->{mid})) {
		$smsg->{'m'} = $m;
	}
	for my $f (qw(from to cc)) {
		my $v = delete $smsg->{$f} or next;
		$smsg->{substr($f, 0, 1)} = pairs($v);
	}
	$smsg->{'s'} = delete $smsg->{subject};
	my $kw = delete($smsg->{kw});
	scalar { %$smsg, ($kw && scalar(@$kw) ? (kw => $kw) : ()) }; # unbless
}

sub ovv_atexit_child {
	my ($self, $lei) = @_;
	if (my $bref = delete $lei->{ovv_buf}) {
		my $lk = $self->lock_for_scope;
		$lei->out($$bref);
	}
}

# JSON module ->pretty output wastes too much vertical white space,
# this (IMHO) provides better use of screen real-estate while not
# being excessively compact:
sub _json_pretty {
	my ($json, $k, $v) = @_;
	if (ref $v eq 'ARRAY') {
		if (@$v) {
			my $sep = ",\n" . (' ' x (length($k) + 7));
			if (ref($v->[0])) { # f/t/c
				$v = '[' . join($sep, map {
					my $pair = $json->encode($_);
					$pair =~ s/(null|"),"/$1, "/g;
					$pair;
				} @$v) . ']';
			} elsif ($k eq 'kw') { # keywords are short, one-line
				$v = $json->encode($v);
				$v =~ s/","/", "/g;
			} else { # refs, labels, ...
				$v = '[' . join($sep, map {
					substr($json->encode([$_]), 1, -1);
				} @$v) . ']';
			}
		} else {
			$v = '[]';
		}
	}
	qq{  "$k": }.$v;
}

sub ovv_each_smsg_cb { # runs in wq worker usually
	my ($self, $lei) = @_;
	my ($json, $dedupe);
	if (my $pkg = $self->{json}) {
		$json = $pkg->new;
		$json->utf8->canonical;
		$json->ascii(1) if $lei->{opt}->{ascii};
	}
	my $l2m = $lei->{l2m};
	if (!$l2m) {
		$dedupe = $lei->{dedupe} // die 'BUG: {dedupe} missing';
		$dedupe->prepare_dedupe;
	}
	$lei->{ovv_buf} = \(my $buf = '') if !$l2m;
	if ($l2m) {
		sub {
			my ($smsg, $mitem, $eml) = @_;
			$smsg->{pct} = get_pct($mitem) if $mitem;
			$l2m->wq_io_do('write_mail', [], $smsg, $eml);
		}
	} elsif ($self->{fmt} =~ /\A(concat)?json\z/ && $lei->{opt}->{pretty}) {
		my $EOR = ($1//'') eq 'concat' ? "\n}" : "\n},";
		my $lse = $lei->{lse};
		sub { # DIY prettiness :P
			my ($smsg, $mitem) = @_;
			return if $dedupe->is_smsg_dup($smsg);
			$lse->xsmsg_vmd($smsg, $smsg->{L} ? undef : 1);
			$smsg = _unbless_smsg($smsg, $mitem);
			$buf .= "{\n";
			$buf .= join(",\n", map {
				my $v = $smsg->{$_};
				if (ref($v)) {
					_json_pretty($json, $_, $v);
				} else {
					$v = $json->encode([$v]);
					qq{  "$_": }.substr($v, 1, -1);
				}
			} sort keys %$smsg);
			$buf .= $EOR;
			return if length($buf) < 65536;
			my $lk = $self->lock_for_scope;
			$lei->out($buf);
			$buf = '';
		}
	} elsif ($json) {
		my $ORS = $self->{fmt} eq 'json' ? ",\n" : "\n"; # JSONL
		my $lse = $lei->{lse};
		sub {
			my ($smsg, $mitem) = @_;
			return if $dedupe->is_smsg_dup($smsg);
			$lse->xsmsg_vmd($smsg, $smsg->{L} ? undef : 1);
			$buf .= $json->encode(_unbless_smsg(@_)) . $ORS;
			return if length($buf) < 65536;
			my $lk = $self->lock_for_scope;
			$lei->out($buf);
			$buf = '';
		}
	} else {
		die "TODO: unhandled case $self->{fmt}"
	}
}

no warnings 'once';
*DESTROY = \&ovv_out_lk_cancel;

1;
