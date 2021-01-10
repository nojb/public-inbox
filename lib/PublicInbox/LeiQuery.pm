# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# handles lei <q|ls-query|rm-query|mv-query> commands
package PublicInbox::LeiQuery;
use strict;
use v5.10.1;
use PublicInbox::MID qw($MID_EXTRACT);
use POSIX qw(strftime);
use PublicInbox::Address qw(pairs);
use PublicInbox::Search qw(get_pct);

sub _iso8601 ($) { strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($_[0])) }

# prepares an smsg for JSON
sub _smsg_unbless ($) {
	my ($smsg) = @_;

	delete @$smsg{qw(lines bytes)};
	$smsg->{rcvd} = _iso8601(delete $smsg->{ts}); # JMAP receivedAt
	$smsg->{dt} = _iso8601(delete $smsg->{ds}); # JMAP UTCDate

	if (my $r = delete $smsg->{references}) {
		$smsg->{references} = [
				map { "<$_>" } ($r =~ m/$MID_EXTRACT/go) ];
	}
	if (my $m = delete($smsg->{mid})) {
		$smsg->{'m'} = "<$m>";
	}
	# XXX breaking to/cc, into structured arrays or tables which
	# distinguish "$phrase <$address>" causes pretty printing JSON
	# to take up too much vertical space.  I can't get either
	# Cpanel::JSON::XS or JSON::XS or jq(1) only indent when
	# wrapping is necessary, rather than blindly indenting and
	# adding vertical space everywhere.
	for my $f (qw(from to cc)) {
		my $v = delete $smsg->{$f} or next;
		$smsg->{substr($f, 0, 1)} = $v;
	}
	$smsg->{'s'} = delete $smsg->{subject};
	# can we be bothered to parse From/To/Cc into arrays?
	scalar { %$smsg }; # unbless
}

sub _vivify_external { # _externals_each callback
	my ($src, $dir) = @_;
	if (-f "$dir/ei.lock") {
		require PublicInbox::ExtSearch;
		push @$src, PublicInbox::ExtSearch->new($dir);
	} elsif (-f "$dir/inbox.lock" || -d "$dir/public-inbox") { # v2, v1
		require PublicInbox::Inbox;
		push @$src, bless { inboxdir => $dir }, 'PublicInbox::Inbox';
	} else {
		warn "W: ignoring $dir, unable to determine type\n";
	}
}

# the main "lei q SEARCH_TERMS" method
sub lei_q {
	my ($self, @argv) = @_;
	my $sto = $self->_lei_store(1);
	my $cfg = $self->_lei_cfg(1);
	my $opt = $self->{opt};
	my $qstr = join(' ', map {;
		# Consider spaces in argv to be for phrase search in Xapian.
		# In other words, the users should need only care about
		# normal shell quotes and not have to learn Xapian quoting.
		/\s/ ? (s/\A(\w+:)// ? qq{$1"$_"} : qq{"$_"}) : $_
	} @argv);
	$opt->{limit} //= 10000;
	my $lxs;
	require PublicInbox::LeiDedupe;
	my $dd = PublicInbox::LeiDedupe->new($self);

	# --local is enabled by default
	my @src = $opt->{'local'} ? ($sto->search) : ();

	# --external is enabled by default, but allow --no-external
	if ($opt->{external} // 1) {
		$self->_externals_each(\&_vivify_external, \@src);
		# {tid} is not unique between indices, so we have to search
		# each src individually
		if (!$opt->{thread}) {
			require PublicInbox::LeiXSearch;
			my $lxs = PublicInbox::LeiXSearch->new;
			# local is always first
			$lxs->attach_external($_) for @src;
			@src = ($lxs);
		}
	}
	my $out = $self->{output} // '-';
	$out = 'json:/dev/stdout' if $out eq '-';
	my $isatty = -t $self->{1};
	$self->start_pager if $isatty;
	my $json = substr($out, 0, 5) eq 'json:' ?
		ref(PublicInbox::Config->json)->new : undef;
	if ($json) {
		if ($opt->{pretty} //= $isatty) {
			$json->pretty(1)->space_before(0);
			$json->indent_length($opt->{indent} // 2);
		}
		$json->utf8; # avoid Wide character in print warnings
		$json->ascii(1) if $opt->{ascii}; # for "\uXXXX"
		$json->canonical;
	}

	# src: LeiXSearch || LeiSearch || Inbox
	my %mset_opt = map { $_ => $opt->{$_} } qw(thread limit offset);
	delete $mset_opt{limit} if $opt->{limit} < 0;
	$mset_opt{asc} = $opt->{'reverse'} ? 1 : 0;
	if (defined(my $sort = $opt->{'sort'})) {
		if ($sort eq 'relevance') {
			$mset_opt{relevance} = 1;
		} elsif ($sort eq 'docid') {
			$mset_opt{relevance} = $mset_opt{asc} ? -1 : -2;
		} elsif ($sort =~ /\Areceived(?:-?[aA]t)?\z/) {
			# the default
		} else {
			die "unrecognized --sort=$sort\n";
		}
	}
	# $self->out($json->encode(\%mset_opt));
	# descending docid order
	$mset_opt{relevance} //= -2 if $opt->{thread};
	# my $wcb = PublicInbox::LeiToMail->write_cb($out, $self);

	# even w/o pretty, do the equivalent of a --pretty=oneline
	# output so "lei q SEARCH_TERMS | wc -l" can be useful:
	my $ORS = $json ? ($opt->{pretty} ? ', ' : ",\n") : "\n";
	my $buf;

	# we can generate too many records to hold in RAM, so we stream
	# and fake a JSON array starting here:
	$self->out('[') if $json;
	my $emit_cb = sub {
		my ($smsg) = @_;
		delete @$smsg{qw(tid num)}; # only makes sense if single src
		chomp($buf = $json->encode(_smsg_unbless($smsg)));
	};
	$dd->prepare_dedupe;
	for my $src (@src) {
		my $srch = $src->search;
		my $over = $src->over;
		my $smsg_for = $src->can('smsg_for'); # LeiXSearch
		my $mo = { %mset_opt };
		my $mset = $srch->mset($qstr, $mo);
		my $ctx = {};
		if ($smsg_for) {
			for my $it ($mset->items) {
				my $smsg = $smsg_for->($srch, $it) or next;
				next if $dd->is_smsg_dup($smsg);
				$self->out($buf .= $ORS) if defined $buf;
				$smsg->{relevance} = get_pct($it);
				$emit_cb->($smsg);
			}
		} else { # --thread
			my $ids = $srch->mset_to_artnums($mset, $mo);
			$ctx->{ids} = $ids;
			my $i = 0;
			my %n2p = map {
				($ids->[$i++], get_pct($_));
			} $mset->items;
			undef $mset;
			while ($over && $over->expand_thread($ctx)) {
				for my $n (@{$ctx->{xids}}) {
					my $t = $over->get_art($n) or next;
					next if $dd->is_smsg_dup($t);
					if (my $p = delete $n2p{$t->{num}}) {
						$t->{relevance} = $p;
					}
					$self->out($buf .= $ORS);
					$emit_cb->($t);
				}
				@{$ctx->{xids}} = ();
			}
		}
	}
	$self->out($buf .= "]\n"); # done
}

1;
