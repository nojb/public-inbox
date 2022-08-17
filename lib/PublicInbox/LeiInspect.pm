# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# "lei inspect" general purpose inspector for stuff in SQLite and
# Xapian.  Will eventually be useful with plain public-inboxes,
# not just lei/store.  This is totally half-baked at the moment
# but useful for testing.
package PublicInbox::LeiInspect;
use strict;
use v5.10.1;
use parent qw(PublicInbox::IPC);
use PublicInbox::Config;
use PublicInbox::MID qw(mids);
use PublicInbox::NetReader qw(imap_uri nntp_uri);
use POSIX qw(strftime);
use PublicInbox::LeiOverview;
*iso8601 = \&PublicInbox::LeiOverview::iso8601;

sub _json_prep ($) {
	my ($smsg) = @_;
	$smsg->{$_} += 0 for qw(bytes lines); # integerize
	$smsg->{dt} = iso8601($smsg->{ds}) if defined($smsg->{ds});
	$smsg->{rt} = iso8601($smsg->{ts}) if defined($smsg->{ts});
	+{ %$smsg } # unbless and scalarize
}

sub inspect_blob ($$) {
	my ($lei, $oidhex) = @_;
	my $ent = {};
	if (my $lse = $lei->{lse}) {
		my $oidbin = pack('H*', $oidhex);
		my @docids = $lse ? $lse->over->oidbin_exists($oidbin) : ();
		$ent->{'lei/store'} = \@docids if @docids;
		my $lms = $lei->lms;
		if (my $loc = $lms ? $lms->locations_for($oidbin) : undef) {
			$ent->{'mail-sync'} = $loc;
		}
	}
	$ent;
}

sub inspect_imap_uid ($$) {
	my ($lei, $uid_uri) = @_;
	my $ent = {};
	my $lms = $lei->lms or return $ent;
	my @oidhex = $lms->imap_oidhex($lei, $uid_uri);
	$ent->{$$uid_uri} = @oidhex == 1 ? $oidhex[0] :
			((@oidhex == 0) ? undef : \@oidhex);
	$ent;
}

sub inspect_nntp_range {
	my ($lei, $uri) = @_;
	my ($ng, $beg, $end) = $uri->group;
	$uri = $uri->clone;
	$uri->group($ng);
	my $ent = {};
	my $ret = { "$uri" => $ent };
	my $lms = $lei->lms or return $ret;
	my $folders = [ $$uri ];
	eval { $lms->arg2folder($lei, $folders) };
	$lei->qerr("# no folders match $$uri (non-fatal)") if $@;
	$end //= $beg;
	for my $art ($beg..$end) {
		my @oidhex = map { unpack('H*', $_) }
			$lms->num_oidbin($folders->[0], $art);
		$ent->{$art} = @oidhex == 1 ? $oidhex[0] :
				((@oidhex == 0) ? undef : \@oidhex);
	}
	$ret;
}

sub inspect_sync_folder ($$) {
	my ($lei, $folder) = @_;
	my $ent = {};
	my $lms = $lei->lms or return $ent;
	my $folders = [ $folder ];
	eval { $lms->arg2folder($lei, $folders) };
	$lei->qerr("# no folders match $folder (non-fatal)") if $@;
	for my $f (@$folders) {
		$ent->{$f} = $lms->location_stats($f); # may be undef
	}
	$ent
}

sub _inspect_doc ($$) {
	my ($ent, $doc) = @_;
	my $data = $doc->get_data;
	$ent->{data_length} = length($data);
	$ent->{description} = $doc->get_description;
	$ent->{$_} = $doc->$_ for (qw(termlist_count values_count));
	my $cur = $doc->termlist_begin;
	my $end = $doc->termlist_end;
	for (; $cur != $end; $cur++) {
		my $tn = $cur->get_termname;
		$tn =~ s/\A([A-Z]+)// or warn "$tn no prefix! (???)";
		my $term = ($1 // '');
		push @{$ent->{terms}->{$term}}, $tn;
	}
	@$_ = sort(@$_) for values %{$ent->{terms} // {}};
	$cur = $doc->values_begin;
	$end = $doc->values_end;
	for (; $cur != $end; $cur++) {
		my $n = $cur->get_valueno;
		my $v = $cur->get_value;
		my $iv = PublicInbox::Search::sortable_unserialise($v);
		$v = $iv + 0 if defined $iv;
		# not using ->[$n] since we may have large gaps in $n
		$ent->{'values'}->{$n} = $v;
	}
	$ent;
}

sub inspect_docid ($$;$) {
	my ($lei, $docid, $ent) = @_;
	require PublicInbox::Search;
	$ent //= {};
	my $xdb;
	if ($xdb = delete $ent->{xdb}) { # from inspect_num
	} elsif (defined(my $dir = $lei->{opt}->{dir})) {
		no warnings 'once';
		$xdb = $PublicInbox::Search::X{Database}->new($dir);
	} elsif ($lei->{lse}) {
		$xdb = $lei->{lse}->xdb;
	}
	$xdb or return $lei->fail('no Xapian DB');
	my $doc = $xdb->get_document($docid); # raises
	$ent->{docid} = $docid;
	_inspect_doc($ent, $doc);
}

sub dir2ibx ($$) {
	my ($lei, $dir) = @_;
	if (-f "$dir/ei.lock") {
		require PublicInbox::ExtSearch;
		PublicInbox::ExtSearch->new($dir);
	} elsif (-f "$dir/inbox.lock" || -d "$dir/public-inbox") {
		require PublicInbox::Inbox; # v2, v1
		bless { inboxdir => $dir }, 'PublicInbox::Inbox';
	} else {
		$lei->fail("no (indexed) inbox or extindex at $dir");
	}
}

sub inspect_num ($$) {
	my ($lei, $num) = @_;
	my ($docid, $ibx);
	my $ent = { num => $num };
	if (defined(my $dir = $lei->{opt}->{dir})) {
		$ibx = dir2ibx($lei, $dir) or return;
		if (my $srch = $ibx->search) {
			$ent->{xdb} = $srch->xdb and
				$docid = $srch->num2docid($num);
		}
	} elsif ($lei->{lse}) {
		$ibx = $lei->{lse};
		$lei->{lse}->xdb; # set {nshard} for num2docid
		$docid = $lei->{lse}->num2docid($num);
	}
	if ($ibx && $ibx->over) {
		my $smsg = $ibx->over->get_art($num);
		$ent->{smsg} = _json_prep($smsg) if $smsg;
	}
	defined($docid) ? inspect_docid($lei, $docid, $ent) : $ent;
}

sub inspect_mid ($$) {
	my ($lei, $mid) = @_;
	my $ibx;
	my $ent = { mid => $mid };
	if (defined(my $dir = $lei->{opt}->{dir})) {
		$ibx = dir2ibx($lei, $dir)
	} else {
		$ibx = $lei->{lse};
	}
	if ($ibx && $ibx->over) {
		my ($id, $prev);
		while (my $smsg = $ibx->over->next_by_mid($mid, \$id, \$prev)) {
			push @{$ent->{smsg}}, _json_prep($smsg);
		}
	}
	if ($ibx && $ibx->search) {
		my $mset = $ibx->search->mset(qq{mid:"$mid"});
		for (sort { $a->get_docid <=> $b->get_docid } $mset->items) {
			my $tmp = { docid => $_->get_docid };
			_inspect_doc($tmp, $_->get_document);
			push @{$ent->{xdoc}}, $tmp;
		}
	}
	$ent;
}

sub inspect1 ($$$) {
	my ($lei, $item, $more) = @_;
	my $ent;
	if ($item =~ /\Ablob:(.+)/) {
		$ent = inspect_blob($lei, $1);
	} elsif ($item =~ m!\A(?:maildir|mh):!i || -d $item) {
		$ent = inspect_sync_folder($lei, $item);
	} elsif ($item =~ m!\Adocid:([0-9]+)\z!) {
		$ent = inspect_docid($lei, $1 + 0);
	} elsif ($item =~ m!\Anum:([0-9]+)\z!) {
		$ent = inspect_num($lei, $1 + 0);
	} elsif ($item =~ m!\A(?:mid|m):(.+)\z!) {
		$ent = inspect_mid($lei, $1);
	} elsif (my $iuri = imap_uri($item)) {
		if (defined($iuri->uid)) {
			$ent = inspect_imap_uid($lei, $iuri);
		} else {
			$ent = inspect_sync_folder($lei, $item);
		}
	} elsif (my $nuri = nntp_uri($item)) {
		if (defined(my $mid = $nuri->message)) {
			$ent = inspect_mid($lei, $mid);
		} else {
			my ($group, $beg, $end) = $nuri->group;
			if (defined($beg)) {
				$ent = inspect_nntp_range($lei, $nuri);
			} else {
				$ent = inspect_sync_folder($lei, $item);
			}
		}
	} else { # TODO: more things
		return $lei->fail("$item not understood");
	}
	$lei->out($lei->{json}->encode($ent));
	$lei->out(',') if $more;
	1;
}

sub inspect_argv { # via wq_do
	my ($self) = @_;
	my ($lei, $argv) = delete @$self{qw(lei argv)};
	my $multi = scalar(@$argv) > 1;
	$lei->{1}->autoflush(0);
	$lei->out('[') if $multi;
	while (defined(my $x = shift @$argv)) {
		eval { inspect1($lei, $x, scalar(@$argv)) or return };
		warn "E: $@\n" if $@;
	}
	$lei->out(']') if $multi;
}

sub inspect_start ($$) {
	my ($lei, $argv) = @_;
	my $self = bless { lei => $lei, argv => $argv }, __PACKAGE__;
	my ($op_c, $ops) = $lei->workers_start($self, 1);
	$lei->{wq1} = $self;
	$lei->wait_wq_events($op_c, $ops);
	$self->wq_do('inspect_argv');
	$self->wq_close;
}

sub ins_add { # InputPipe->consume callback
	my ($lei) = @_; # $_[1] = $rbuf
	if (defined $_[1]) {
		$_[1] eq '' and return eval {
			my $str = delete $lei->{istr};
			$str =~ s/\A[\r\n]*From [^\r\n]*\r?\n//s;
			my $eml = PublicInbox::Eml->new(\$str);
			inspect_start($lei, [
				'blob:'.$lei->git_oid($eml)->hexdigest,
				map { "mid:$_" } @{mids($eml)} ]);
		};
		$lei->{istr} .= $_[1];
	} else {
		$lei->fail("error reading stdin: $!");
	}
}

sub lei_inspect {
	my ($lei, @argv) = @_;
	$lei->{json} = ref(PublicInbox::Config::json())->new->utf8->canonical;
	$lei->{lse} = ($lei->{opt}->{external} // 1) ? do {
		my $sto = $lei->_lei_store;
		$sto ? $sto->search : undef;
	} : undef;
	my $isatty = -t $lei->{1};
	$lei->{json}->pretty(1)->indent(2) if $lei->{opt}->{pretty} || $isatty;
	$lei->start_pager if $isatty;
	if ($lei->{opt}->{stdin}) {
		return $lei->fail(<<'') if @argv;
no args allowed on command-line with --stdin

		require PublicInbox::InputPipe;
		PublicInbox::InputPipe::consume($lei->{0}, \&ins_add, $lei);
	} else {
		inspect_start($lei, \@argv);
	}
}

sub _complete_inspect {
	require PublicInbox::LeiRefreshMailSync;
	PublicInbox::LeiRefreshMailSync::_complete_refresh_mail_sync(@_);
	# TODO: message-ids?, blobs? could get expensive...
}

sub ipc_atfork_child {
	my ($self) = @_;
	$self->{lei}->_lei_atfork_child;
	$self->SUPER::ipc_atfork_child;
}

1;
