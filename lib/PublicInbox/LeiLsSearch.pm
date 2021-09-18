# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# "lei ls-search" to display results saved via "lei q --save"
package PublicInbox::LeiLsSearch;
use strict;
use v5.10.1;
use PublicInbox::LeiSavedSearch;
use parent qw(PublicInbox::IPC);

sub do_ls_search_long {
	my ($self, $pfx) = @_;
	# TODO: share common JSON output code with LeiOverview
	my $json = $self->{json}->new->utf8->canonical;
	my $lei = $self->{lei};
	$json->ascii(1) if $lei->{opt}->{ascii};
	my $fmt = $lei->{opt}->{'format'};
	$lei->{1}->autoflush(0);
	my $ORS = "\n";
	my $pretty = $lei->{opt}->{pretty};
	my $EOR;  # TODO: compact pretty like "lei q"
	if ($fmt =~ /\A(concat)?json\z/ && $pretty) {
		$EOR = ($1//'') eq 'concat' ? "\n}" : "\n},";
	}
	if ($fmt eq 'json') {
		$lei->out('[');
		$ORS = ",\n";
	}
	my @x = sort(grep(/\A\Q$pfx/, PublicInbox::LeiSavedSearch::list($lei)));
	while (my $x = shift @x) {
		$ORS = '' if !scalar(@x);
		my $lss = PublicInbox::LeiSavedSearch->up($lei, $x) or next;
		my $cfg = $lss->{-cfg};
		my $ent = {
			q => $cfg->get_all('lei.q'),
			output => $cfg->{'lei.q.output'},
		};
		for my $k ($lss->ARRAY_FIELDS) {
			my $ary = $cfg->get_all("lei.q.$k") // next;
			$ent->{$k} = $ary;
		}
		for my $k ($lss->BOOL_FIELDS) {
			my $val = $cfg->{"lei.q.$k"} // next;
			$ent->{$k} = $val;
		}
		if (defined $EOR) { # pretty, but compact
			$EOR = "\n}" if !scalar(@x);
			my $buf = "{\n";
			$buf .= join(",\n", map {;
				my $f = $_;
				if (my $v = $ent->{$f}) {
					$v = $json->encode([$v]);
					qq{  "$f": }.substr($v, 1, -1);
				} else {
					();
				}
			# key order by importance
			} (qw(output q), $lss->ARRAY_FIELDS,
				$lss->BOOL_FIELDS) );
			$lei->out($buf .= $EOR);
		} else {
			$lei->out($json->encode($ent), $ORS);
		}
	}
	if ($fmt eq 'json') {
		$lei->out("]\n");
	} elsif ($fmt eq 'concatjson') {
		$lei->out("\n");
	}
}

sub bg_worker ($$$) {
	my ($lei, $pfx, $json) = @_;
	my $self = bless { json => $json }, __PACKAGE__;
	my ($op_c, $ops) = $lei->workers_start($self, 1);
	$lei->{wq1} = $self;
	$self->wq_io_do('do_ls_search_long', [], $pfx);
	$self->wq_close(1);
	$lei->wait_wq_events($op_c, $ops);
}

sub lei_ls_search {
	my ($lei, $pfx) = @_;
	my $fmt = $lei->{opt}->{'format'} // '';
	if ($lei->{opt}->{l}) {
		$lei->{opt}->{'format'} //= $fmt = 'json';
	}
	my $json;
	my $tty = -t $lei->{1};
	$lei->start_pager if $tty;
	if ($fmt =~ /\A(ldjson|ndjson|jsonl|(?:concat)?json)\z/) {
		$lei->{opt}->{pretty} //= $tty;
		$json = ref(PublicInbox::Config->json);
	} elsif ($fmt ne '') {
		return $lei->fail("unknown format: $fmt");
	}
	my $ORS = "\n";
	if ($lei->{opt}->{z}) {
		return $lei->fail('-z and --format do not mix') if $json;
		$ORS = "\0";
	}
	$pfx //= '';
	return bg_worker($lei, $pfx, $json) if $json;
	for (sort(grep(/\A\Q$pfx/, PublicInbox::LeiSavedSearch::list($lei)))) {
		$lei->out($_, $ORS);
	}
}

1;
