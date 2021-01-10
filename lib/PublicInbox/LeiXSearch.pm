# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Combine any combination of PublicInbox::Search,
# PublicInbox::ExtSearch, and PublicInbox::LeiSearch objects
# into one Xapian DB
package PublicInbox::LeiXSearch;
use strict;
use v5.10.1;
use parent qw(PublicInbox::LeiSearch PublicInbox::IPC);
use PublicInbox::Search qw(get_pct);

sub new {
	my ($class) = @_;
	PublicInbox::Search::load_xapian();
	bless {
		qp_flags => $PublicInbox::Search::QP_FLAGS |
				PublicInbox::Search::FLAG_PURE_NOT(),
	}, $class
}

sub attach_external {
	my ($self, $ibxish) = @_; # ibxish = ExtSearch or Inbox

	if (!$ibxish->can('over') || !$ibxish->over) {
		return push(@{$self->{remotes}}, $ibxish)
	}
	my $desc = $ibxish->{inboxdir} // $ibxish->{topdir};
	my $srch = $ibxish->search or
		return warn("$desc not indexed for Xapian\n");
	my @shards = $srch->xdb_shards_flat or
		return warn("$desc has no Xapian shardsXapian\n");

	if (delete $self->{xdb}) { # XXX: do we need this?
		# clobber existing {xdb} if amending
		my $expect = delete $self->{nshard};
		my $shards = delete $self->{shards_flat};
		scalar(@$shards) == $expect or die
			"BUG: {nshard}$expect != shards=".scalar(@$shards);

		my $prev = {};
		for my $old_ibxish (@{$self->{shard2ibx}}) {
			next if $prev == $old_ibxish;
			$prev = $old_ibxish;
			my @shards = $old_ibxish->search->xdb_shards_flat;
			push @{$self->{shards_flat}}, @shards;
		}
		my $nr = scalar(@{$self->{shards_flat}});
		$nr == $expect or die
			"BUG: reloaded $nr shards, expected $expect"
	}
	push @{$self->{shards_flat}}, @shards;
	push(@{$self->{shard2ibx}}, $ibxish) for (@shards);
}

# returns a list of local inboxes (or count in scalar context)
sub locals {
	my %uniq = map {; "$_" => $_ } @{$_[0]->{shard2ibx} // []};
	values %uniq;
}

# called by PublicInbox::Search::xdb
sub xdb_shards_flat { @{$_[0]->{shards_flat} // []} }

# like over->get_art
sub smsg_for {
	my ($self, $mitem) = @_;
	# cf. https://trac.xapian.org/wiki/FAQ/MultiDatabaseDocumentID
	my $nshard = $self->{nshard};
	my $docid = $mitem->get_docid;
	my $shard = ($docid - 1) % $nshard;
	my $num = int(($docid - 1) / $nshard) + 1;
	my $smsg = $self->{shard2ibx}->[$shard]->over->get_art($num);
	$smsg->{docid} = $docid;
	$smsg;
}

sub recent {
	my ($self, $qstr, $opt) = @_;
	$opt //= {};
	$opt->{relevance} //= -2;
	$self->mset($qstr //= 'bytes:1..', $opt);
}

sub over {}

sub _mset_more ($$) {
	my ($mset, $mo) = @_;
	my $size = $mset->size;
	$size && (($mo->{offset} += $size) < ($mo->{limit} // 10000));
}

sub query_thread_mset { # for --thread
	my ($self, $lei, $ibxish) = @_;
	my ($srch, $over) = ($ibxish->search, $ibxish->over);
	unless ($srch && $over) {
		my $desc = $ibxish->{inboxdir} // $ibxish->{topdir};
		warn "$desc not indexed by Xapian\n";
		return;
	}
	local %SIG = (%SIG, $lei->atfork_child_wq($self));
	my $mo = { %{$lei->{mset_opt}} };
	my $mset;
	do {
		$mset = $srch->mset($mo->{qstr}, $mo);
		my $ids = $srch->mset_to_artnums($mset, $mo);
		my $ctx = { ids => $ids };
		my $i = 0;
		my %n2p = map { ($ids->[$i++], get_pct($_)) } $mset->items;
		while ($over->expand_thread($ctx)) {
			for my $n (@{$ctx->{xids}}) {
				my $smsg = $over->get_art($n) or next;
				# next if $dd->is_smsg_dup($smsg); TODO
				if (my $p = delete $n2p{$smsg->{num}}) {
					$smsg->{relevance} = $p;
				}
				print { $self->{1} } Dumper($smsg);
				# $self->out($buf .= $ORS);
				# $emit_cb->($smsg);
			}
			@{$ctx->{xids}} = ();
		}
	} while (_mset_more($mset, $mo));
}

sub query_mset { # non-parallel for non-"--thread" users
	my ($self, $lei, $srcs) = @_;
	my $mo = { %{$lei->{mset_opt}} };
	my $mset;
	local %SIG = (%SIG, $lei->atfork_child_wq($self));
	$self->attach_external($_) for @$srcs;
	do {
		$mset = $self->mset($mo->{qstr}, $mo);
		for my $it ($mset->items) {
			my $smsg = smsg_for($self, $it) or next;
			# next if $dd->is_smsg_dup($smsg);
			$smsg->{relevance} = get_pct($it);
			use Data::Dumper;
			print { $self->{1} } Dumper($smsg);
			# $self->out($buf .= $ORS) if defined $buf;
			#$emit_cb->($smsg);
		}
	} while (_mset_more($mset, $mo));
}

sub do_query {
	my ($self, $lei_orig, $srcs) = @_;
	my ($lei, @io) = $lei_orig->atfork_prepare_wq($self);
	$io[1]->autoflush(1);
	$io[2]->autoflush(1);
	if ($lei->{opt}->{thread}) {
		for my $ibxish (@$srcs) {
			$self->wq_do('query_thread_mset', \@io, $lei, $ibxish);
		}
	} else {
		$self->wq_do('query_mset', \@io, $lei, $srcs);
	}
	# TODO
	for my $rmt (@{$self->{remotes} // []}) {
		$self->wq_do('query_thread_mbox', \@io, $lei, $rmt);
	}
}

1;
