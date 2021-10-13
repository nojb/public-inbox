# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# front-end for the "lei patch-to-query" sub-command
package PublicInbox::LeiP2q;
use strict;
use v5.10.1;
use parent qw(PublicInbox::IPC);
use PublicInbox::Eml;
use PublicInbox::Smsg;
use PublicInbox::MsgIter qw(msg_part_text);
use PublicInbox::Git qw(git_unquote);
use PublicInbox::Spawn qw(popen_rd);
use URI::Escape qw(uri_escape_utf8);
my $FN = qr!((?:"?[^/\n]+/[^\r\n]+)|/dev/null)!;

sub xphrase ($) {
	my ($s) = @_;
	return () unless $s =~ /\S/;
	# cf. xapian-core/queryparser/queryparser.lemony
	# [\./:\\\@] - is_phrase_generator (implicit phrase search)
	# FIXME not really sure about these..., we basically want to
	# extract the longest phrase possible that Xapian can handle
	map {
		s/\A\s*//;
		s/\s+\z//;
		m![^\./:\\\@\-\w]! ? qq("$_") : $_ ;
	} ($s =~ m!(\w[\|=><,\./:\\\@\-\w\s]+)!g);
}

sub extract_terms { # eml->each_part callback
	my ($p, $lei) = @_;
	my $part = $p->[0]; # ignore $depth and @idx;
	my $ct = $part->content_type || 'text/plain';
	my ($s, undef) = msg_part_text($part, $ct);
	defined $s or return;
	my $in_diff;
	# TODO: b: nq: q:
	for (split(/\n/, $s)) {
		if ($in_diff && s/^ //) { # diff context
			push @{$lei->{qterms}->{dfctx}}, xphrase($_);
		} elsif (/^-- $/) { # email signature begins
			$in_diff = undef;
		} elsif (m!^diff --git $FN $FN!) {
			# wait until "---" and "+++" to capture filenames
			$in_diff = 1;
		} elsif (/^index ([a-f0-9]+)\.\.([a-f0-9]+)\b/) {
			my ($oa, $ob) = ($1, $2);
			push @{$lei->{qterms}->{dfpre}}, $oa;
			push @{$lei->{qterms}->{dfpost}}, $ob;
			# who uses dfblob?
		} elsif (m!^(?:---|\+{3}) ($FN)!) {
			next if $1 eq '/dev/null';
			my $fn = (split(m!/!, git_unquote($1.''), 2))[1];
			push @{$lei->{qterms}->{dfn}}, xphrase($fn);
		} elsif ($in_diff && s/^\+//) { # diff added
			push @{$lei->{qterms}->{dfb}}, xphrase($_);
		} elsif ($in_diff && s/^-//) { # diff removed
			push @{$lei->{qterms}->{dfa}}, xphrase($_);
		} elsif (/^@@ (?:\S+) (?:\S+) @@\s*$/) {
			# traditional diff w/o -p
		} elsif (/^@@ (?:\S+) (?:\S+) @@\s*(\S+.*)/) {
			push @{$lei->{qterms}->{dfhh}}, xphrase($1);
		} elsif (/^(?:dis)similarity index/ ||
				/^(?:old|new) mode/ ||
				/^(?:deleted|new) file mode/ ||
				/^(?:copy|rename) (?:from|to) / ||
				/^(?:dis)?similarity index / ||
				/^\\ No newline at end of file/ ||
				/^Binary files .* differ/) {
		} elsif ($_ eq '') {
			# possible to be in diff context, some mail may be
			# stripped by MUA or even GNU diff(1).  "git apply"
			# treats a bare "\n" as diff context, too
		} else {
			$in_diff = undef;
		}
	}
}

my %pfx2smsg = (
	t => [ qw(to) ],
	c => [ qw(cc) ],
	f => [ qw(from) ],
	tc => [ qw(to cc) ],
	tcf => [ qw(to cc from) ],
	a => [ qw(to cc from) ],
	s => [ qw(subject) ],
	bs => [ qw(subject) ], # body handled elsewhere
	d => [ qw(ds) ], # nonsense?
	dt => [ qw(ds) ], # ditto...
	rt => [ qw(ts) ], # ditto...
);

sub do_p2q { # via wq_do
	my ($self) = @_;
	my $lei = $self->{lei};
	my $want = $lei->{opt}->{want} // [ qw(dfpost7) ];
	my @want = split(/[, ]+/, "@$want");
	for (@want) {
		/\A(?:(d|dt|rt):)?([0-9]+)(\.(?:day|weeks)s?)?\z/ or next;
		my ($pfx, $n, $unit) = ($1, $2, $3);
		$n *= 86400 * ($unit =~ /week/i ? 7 : 1);
		$_ = [ $pfx, $n ];
	}
	my $smsg = bless {}, 'PublicInbox::Smsg';
	my $in = $self->{0};
	my @cmd;
	unless ($in) {
		my $input = $self->{input};
		my $devfd = $lei->path_to_fd($input) // return;
		if ($devfd >= 0) {
			$in = $lei->{$devfd};
		} elsif (-e $input) {
			open($in, '<', $input) or
				return $lei->fail("open < $input: $!");
		} else {
			@cmd = (qw(git format-patch --stdout -1), $input);
			$in = popen_rd(\@cmd, undef, { 2 => $lei->{2} });
		}
	};
	my $str = do { local $/; <$in> };
	@cmd && !close($in) and return $lei->fail("E: @cmd failed: $?");
	my $eml = PublicInbox::Eml->new(\$str);
	$lei->{diff_want} = +{ map { $_ => 1 } @want };
	$smsg->populate($eml);
	while (my ($pfx, $fields) = each %pfx2smsg) {
		next unless $lei->{diff_want}->{$pfx};
		for my $f (@$fields) {
			my $v = $smsg->{$f} // next;
			push @{$lei->{qterms}->{$pfx}}, xphrase($v);
		}
	}
	$eml->each_part(\&extract_terms, $lei, 1);
	if ($lei->{opt}->{debug}) {
		my $json = ref(PublicInbox::Config->json)->new;
		$json->utf8->canonical->pretty;
		print { $lei->{2} } $json->encode($lei->{qterms});
	}
	my (@q, %seen);
	for my $pfx (@want) {
		if (ref($pfx) eq 'ARRAY') {
			my ($p, $t_range) = @$pfx; # TODO

		} elsif ($pfx =~ m!\A(?:OR|XOR|AND|NOT)\z! ||
				$pfx =~ m!\A(?:ADJ|NEAR)(?:/[0-9]+)?\z!) {
			push @q, $pfx;
		} else {
			my $plusminus = ($pfx =~ s/\A([\+\-])//) ? $1 : '';
			my $end = ($pfx =~ s/([0-9\*]+)\z//) ? $1 : '';
			my $x = delete($lei->{qterms}->{$pfx}) or next;
			my $star = $end =~ tr/*//d ? '*' : '';
			my $min_len = ($end || 0) + 0;

			# no wildcards for bool_pfx_external
			$star = '' if $pfx =~ /\A(dfpre|dfpost|mid)\z/;
			$pfx = "$plusminus$pfx:";
			if ($min_len) {
				push @q, map {
					my @t = ($pfx.$_.$star);
					while (length > $min_len) {
						chop $_;
						push @t, 'OR', $pfx.$_.$star;
					}
					@t;
				} @$x;
			} else {
				push @q, map {
					my $k = $pfx.$_.$star;
					$seen{$k}++ ? () : $k
				} @$x;
			}
		}
	}
	if ($lei->{opt}->{uri}) {
		@q = (join('+', map { uri_escape_utf8($_) } @q));
	} else {
		@q = (join(' ', @q));
	}
	$lei->out(@q, "\n");
}

sub lei_p2q { # the "lei patch-to-query" entry point
	my ($lei, $input) = @_;
	my $self = bless {}, __PACKAGE__;
	if ($lei->{opt}->{stdin}) {
		$self->{0} = delete $lei->{0}; # guard from _lei_atfork_child
	} else {
		$self->{input} = $input;
	}
	my ($op_c, $ops) = $lei->workers_start($self, 1);
	$lei->{wq1} = $self;
	$self->wq_io_do('do_p2q', []);
	$self->wq_close(1);
	$lei->wait_wq_events($op_c, $ops);
}

sub ipc_atfork_child {
	my ($self) = @_;
	$self->{lei}->_lei_atfork_child;
	$self->SUPER::ipc_atfork_child;
}

1;
