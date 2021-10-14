# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# read-only counterpart for PublicInbox::LeiStore
package PublicInbox::LeiSearch;
use strict;
use v5.10.1;
use parent qw(PublicInbox::ExtSearch); # PublicInbox::Search->reopen
use PublicInbox::Search qw(xap_terms);
use PublicInbox::ContentHash qw(content_digest content_hash);
use PublicInbox::MID qw(mids mids_for_index);
use Carp qw(croak);

sub _msg_kw { # retry_reopen callback
	my ($self, $num) = @_;
	my $xdb = $self->xdb; # set {nshard} for num2docid;
	xap_terms('K', $xdb, $self->num2docid($num));
}

sub msg_keywords { # array or hashref
	my ($self, $num) = @_;
	$self->retry_reopen(\&_msg_kw, $num);
}

sub _oid_kw { # retry_reopen callback
	my ($self, $nums) = @_;
	my $xdb = $self->xdb; # set {nshard};
	my %kw;
	for my $num (@$nums) { # there should only be one...
		my $doc = $xdb->get_document($self->num2docid($num));
		my $x = xap_terms('K', $doc);
		%kw = (%kw, %$x);
	}
	\%kw;
}

# returns undef if blob is unknown
sub oidbin_keywords {
	my ($self, $oidbin) = @_;
	my @num = $self->over->oidbin_exists($oidbin) or return;
	$self->retry_reopen(\&_oid_kw, \@num);
}

sub _xsmsg_vmd { # retry_reopen
	my ($self, $smsg, $want_label) = @_;
	my $xdb = $self->xdb; # set {nshard};
	my (%kw, %L, $doc, $x);
	$kw{flagged} = 1 if delete($smsg->{lei_q_tt_flagged});
	my @num = $self->over->blob_exists($smsg->{blob});
	for my $num (@num) { # there should only be one...
		$doc = $xdb->get_document($self->num2docid($num));
		$x = xap_terms('K', $doc);
		%kw = (%kw, %$x);
		if ($want_label) { # JSON/JMAP only
			$x = xap_terms('L', $doc);
			%L = (%L, %$x);
		}
	}
	$smsg->{kw} = [ sort keys %kw ] if scalar(keys(%kw));
	$smsg->{L} = [ sort keys %L ] if scalar(keys(%L));
}

# lookup keywords+labels for external messages
sub xsmsg_vmd {
	my ($self, $smsg, $want_label) = @_;
	return if $smsg->{kw}; # already set by LeiXSearch->mitem_kw
	eval { $self->retry_reopen(\&_xsmsg_vmd, $smsg, $want_label) };
	warn "$$ $0 (nshard=$self->{nshard}) $smsg->{blob}: $@" if $@;
}

# when a message has no Message-IDs at all, this is needed for
# unsent Draft messages, at least
sub content_key ($) {
	my ($eml) = @_;
	my $dig = content_digest($eml);
	my $chash = $dig->clone->digest;
	my $mids = mids_for_index($eml);
	unless (@$mids) {
		$eml->{-lei_fake_mid} = $mids->[0] =
				PublicInbox::Import::digest2mid($dig, $eml, 0);
	}
	($chash, $mids);
}

sub _cmp_1st { # git->cat_async callback
	my ($bref, $oid, $type, $size, $cmp) = @_;
	# cmp: [chash, xoids, smsg, lms]
	$bref //= $cmp->[3] ? $cmp->[3]->local_blob($oid, 1) : undef;
	if ($bref && content_hash(PublicInbox::Eml->new($bref)) eq $cmp->[0]) {
		$cmp->[1]->{$oid} = $cmp->[2]->{num};
	}
}

# returns { OID => num } mapping for $eml matches
# The `num' hash value only makes sense from LeiSearch itself
# and is nonsense from the PublicInbox::LeiALE subclass
sub xoids_for {
	my ($self, $eml, $min) = @_;
	my ($chash, $mids) = content_key($eml);
	my @overs = ($self->over // $self->overs_all);
	my $git = $self->git;
	my $xoids = {};
	# no lms when used via {ale}:
	my $lms = $self->{-lms_ro} //= lms($self) if defined($self->{topdir});
	for my $mid (@$mids) {
		for my $o (@overs) {
			my ($id, $prev);
			while (my $cur = $o->next_by_mid($mid, \$id, \$prev)) {
				next if $cur->{bytes} == 0 ||
					$xoids->{$cur->{blob}};
				$git->cat_async($cur->{blob}, \&_cmp_1st,
						[$chash, $xoids, $cur, $lms]);
				if ($min && scalar(keys %$xoids) >= $min) {
					$git->async_wait_all;
					return $xoids;
				}
			}
		}
	}
	$git->async_wait_all;
	scalar(keys %$xoids) ? $xoids : undef;
}

# returns true if $eml is indexed by lei/store and keywords don't match
sub kw_changed {
	my ($self, $eml, $new_kw_sorted, $docids) = @_;
	my $cur_kw;
	if ($eml) {
		my $xoids = xoids_for($self, $eml) // return;
		$docids //= [];
		@$docids = sort { $a <=> $b } values %$xoids;
	}
	for my $id (@$docids) {
		$cur_kw = eval { msg_keywords($self, $id) } and last;
	}
	if (!defined($cur_kw) && $@) {
		$docids = join(', num:', @$docids);
		croak "E: num:$docids keyword lookup failure: $@";
	}
	# RFC 5550 sec 5.9 on the $Forwarded keyword states:
	# "Once set, the flag SHOULD NOT be cleared"
	if (exists($cur_kw->{forwarded}) &&
			!grep(/\Aforwarded\z/, @$new_kw_sorted)) {
		delete $cur_kw->{forwarded};
	}
	$cur_kw = join("\0", sort keys %$cur_kw);
	join("\0", @$new_kw_sorted) eq $cur_kw ? 0 : 1;
}

sub all_terms {
	my ($self, $pfx) = @_;
	my $xdb = $self->xdb;
	my $cur = $xdb->allterms_begin($pfx);
	my $end = $xdb->allterms_end($pfx);
	my %ret;
	for (; $cur != $end; $cur++) {
		my $tn = $cur->get_termname;
		index($tn, $pfx) == 0 and
			$ret{substr($tn, length($pfx))} = undef;
	}
	wantarray ? (sort keys %ret) : \%ret;
}

sub qparse_new {
	my ($self) = @_;
	my $qp = $self->SUPER::qparse_new; # PublicInbox::Search
	$qp->add_boolean_prefix('kw', 'K');
	$qp->add_boolean_prefix('L', 'L');
	$qp
}

sub lms {
	my ($self) = @_;
	require PublicInbox::LeiMailSync;
	my $f = "$self->{topdir}/mail_sync.sqlite3";
	-f $f ? PublicInbox::LeiMailSync->new($f) : undef;
}

# allow SolverGit->resolve_patch to work with "lei index"
sub smsg_eml {
	my ($self, $smsg) = @_;
	PublicInbox::Inbox::smsg_eml($self, $smsg) // do {
		my $lms = lms($self);
		my $bref = $lms ? $lms->local_blob($smsg->{blob}, 1) : undef;
		$bref ? PublicInbox::Eml->new($bref) : undef;
	};
}

1;
