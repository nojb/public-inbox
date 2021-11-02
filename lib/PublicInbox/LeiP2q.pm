# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# front-end for the "lei patch-to-query" sub-command
package PublicInbox::LeiP2q;
use strict;
use v5.10.1;
use parent qw(PublicInbox::IPC PublicInbox::LeiInput);
use PublicInbox::Eml;
use PublicInbox::Smsg;
use PublicInbox::MsgIter qw(msg_part_text);
use PublicInbox::Git qw(git_unquote);
use PublicInbox::OnDestroy;
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

sub add_qterm ($$@) {
	my ($self, $p, @v) = @_;
	for (@v) {
		$self->{qseen}->{"$p\0$_"} //=
			push(@{$self->{qterms}->{$p}}, $_);
	}
}

sub extract_terms { # eml->each_part callback
	my ($p, $self) = @_;
	my $part = $p->[0]; # ignore $depth and @idx;
	my $ct = $part->content_type || 'text/plain';
	my ($s, undef) = msg_part_text($part, $ct);
	defined $s or return;
	my $in_diff;
	# TODO: b: nq: q:
	for (split(/\n/, $s)) {
		if ($in_diff && s/^ //) { # diff context
			add_qterm($self, 'dfctx', xphrase($_));
		} elsif (/^-- $/) { # email signature begins
			$in_diff = undef;
		} elsif (m!^diff --git $FN $FN!) {
			# wait until "---" and "+++" to capture filenames
			$in_diff = 1;
		} elsif (/^index ([a-f0-9]+)\.\.([a-f0-9]+)\b/) {
			my ($oa, $ob) = ($1, $2);
			add_qterm($self, 'dfpre', $oa);
			add_qterm($self, 'dfpost', $ob);
			# who uses dfblob?
		} elsif (m!^(?:---|\+{3}) ($FN)!) {
			next if $1 eq '/dev/null';
			my $fn = (split(m!/!, git_unquote($1.''), 2))[1];
			add_qterm($self, 'dfn', xphrase($fn));
		} elsif ($in_diff && s/^\+//) { # diff added
			add_qterm($self, 'dfb', xphrase($_));
		} elsif ($in_diff && s/^-//) { # diff removed
			add_qterm($self, 'dfa', xphrase($_));
		} elsif (/^@@ (?:\S+) (?:\S+) @@\s*$/) {
			# traditional diff w/o -p
		} elsif (/^@@ (?:\S+) (?:\S+) @@\s*(\S+.*)/) {
			add_qterm($self, 'dfhh', xphrase($1));
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

sub input_eml_cb { # used by PublicInbox::LeiInput::input_fh
	my ($self, $eml) = @_;
	my $diff_want = $self->{diff_want} // do {
		my $want = $self->{lei}->{opt}->{want} // [ qw(dfpost7) ];
		my @want = split(/[, ]+/, "@$want");
		for (@want) {
			/\A(?:(d|dt|rt):)?([0-9]+)(\.(?:day|weeks)s?)?\z/
				or next;
			my ($pfx, $n, $unit) = ($1, $2, $3);
			$n *= 86400 * ($unit =~ /week/i ? 7 : 1);
			$_ = [ $pfx, $n ];
		}
		$self->{want_order} = \@want;
		$self->{diff_want} = +{ map { $_ => 1 } @want };
	};
	my $smsg = bless {}, 'PublicInbox::Smsg';
	$smsg->populate($eml);
	while (my ($pfx, $fields) = each %pfx2smsg) {
		next unless $diff_want->{$pfx};
		for my $f (@$fields) {
			my $v = $smsg->{$f} // next;
			add_qterm($self, $pfx, xphrase($v));
		}
	}
	$eml->each_part(\&extract_terms, $self, 1);
}

sub emit_query {
	my ($self) = @_;
	my $lei = $self->{lei};
	if ($lei->{opt}->{debug}) {
		my $json = ref(PublicInbox::Config->json)->new;
		$json->utf8->canonical->pretty;
		print { $lei->{2} } $json->encode($self->{qterms});
	}
	my (@q, %seen);
	for my $pfx (@{$self->{want_order}}) {
		if (ref($pfx) eq 'ARRAY') {
			my ($p, $t_range) = @$pfx; # TODO

		} elsif ($pfx =~ m!\A(?:OR|XOR|AND|NOT)\z! ||
				$pfx =~ m!\A(?:ADJ|NEAR)(?:/[0-9]+)?\z!) {
			push @q, $pfx;
		} else {
			my $plusminus = ($pfx =~ s/\A([\+\-])//) ? $1 : '';
			my $end = ($pfx =~ s/([0-9\*]+)\z//) ? $1 : '';
			my $x = delete($self->{qterms}->{$pfx}) or next;
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
	my ($lei, @inputs) = @_;
	$lei->{opt}->{'in-format'} //= 'eml' if $lei->{opt}->{stdin};
	my $self = bless { missing_ok => 1 }, __PACKAGE__;
	$self->prepare_inputs($lei, \@inputs) or return;
	$lei->wq1_start($self);
}

sub ipc_atfork_child {
	my ($self) = @_;
	PublicInbox::LeiInput::input_only_atfork_child($self);
	PublicInbox::OnDestroy->new($$, \&emit_query, $self);
}

no warnings 'once';
*net_merge_all_done = \&PublicInbox::LeiInput::input_only_net_merge_all_done;

1;
