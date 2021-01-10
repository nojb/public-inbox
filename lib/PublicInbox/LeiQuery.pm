# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# handles lei <q|ls-query|rm-query|mv-query> commands
package PublicInbox::LeiQuery;
use strict;
use v5.10.1;
use PublicInbox::MID qw($MID_EXTRACT);
use POSIX qw(strftime);
use PublicInbox::Address qw(pairs);
use PublicInbox::DS qw(dwaitpid);

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
	require PublicInbox::LeiDedupe;
	my $dd = PublicInbox::LeiDedupe->new($self);

	# --local is enabled by default
	# src: LeiXSearch || LeiSearch || Inbox
	my @srcs;
	require PublicInbox::LeiXSearch;
	my $lxs = PublicInbox::LeiXSearch->new;

	# --external is enabled by default, but allow --no-external
	if ($opt->{external} // 1) {
		$self->_externals_each(\&_vivify_external, \@srcs);
	}
	my $j = $opt->{jobs} // scalar(@srcs) > 3 ? 3 : scalar(@srcs);
	$j = 1 if !$opt->{thread};
	$j++ if $opt->{'local'}; # for sto->search below
	if ($self->{sock}) {
		$self->atfork_prepare_wq($lxs);
		$lxs->wq_workers_start('lei_xsearch', $j, $self->oldset)
			// $self->wq_workers($j);
	}
	unshift(@srcs, $sto->search) if $opt->{'local'};
	my $out = $opt->{output} // '-';
	$out = 'json:/dev/stdout' if $out eq '-';
	my $isatty = -t $self->{1};
	# no forking workers after this
	my $pid_old12 = $self->start_pager if $isatty;
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

	my %mset_opt = map { $_ => $opt->{$_} } qw(thread limit offset);
	$mset_opt{asc} = $opt->{'reverse'} ? 1 : 0;
	$mset_opt{qstr} = join(' ', map {;
		# Consider spaces in argv to be for phrase search in Xapian.
		# In other words, the users should need only care about
		# normal shell quotes and not have to learn Xapian quoting.
		/\s/ ? (s/\A(\w+:)// ? qq{$1"$_"} : qq{"$_"}) : $_
	} @argv);
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
	$self->{mset_opt} = \%mset_opt;
	$lxs->do_query($self, \@srcs);
	if ($pid_old12) {
		$self->{$_} = $pid_old12->[$_] for (1, 2);
		dwaitpid($pid_old12->[0], undef, $self->{sock});
	}
}

1;
