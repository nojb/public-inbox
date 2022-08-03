# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# like PublicInbox::SearchIdx, but for searching for non-mail messages.
# Things indexed include:
# * inboxes themselves
# * epoch information
# * (maybe) git code repository information
# Expect ~100K-1M documents with no parallelism opportunities,
# so no sharding, here.
#
# See MiscSearch for read-only counterpart
package PublicInbox::MiscIdx;
use strict;
use v5.10.1;
use PublicInbox::InboxWritable;
use PublicInbox::Search; # for SWIG Xapian and Search::Xapian compat
use PublicInbox::SearchIdx qw(index_text term_generator add_val);
use Carp qw(croak);
use File::Path ();
use PublicInbox::MiscSearch;
use PublicInbox::Config;
use PublicInbox::Syscall;
my $json;

sub new {
	my ($class, $eidx) = @_;
	PublicInbox::SearchIdx::load_xapian_writable();
	my $mi_dir = "$eidx->{xpfx}/misc";
	File::Path::mkpath($mi_dir);
	PublicInbox::Syscall::nodatacow_dir($mi_dir);
	my $flags = $PublicInbox::SearchIdx::DB_CREATE_OR_OPEN;
	$flags |= $PublicInbox::SearchIdx::DB_NO_SYNC if $eidx->{-no_fsync};
	$flags |= $PublicInbox::SearchIdx::DB_DANGEROUS if $eidx->{-dangerous};
	$json //= PublicInbox::Config::json();
	bless {
		mi_dir => $mi_dir,
		flags => $flags,
		indexlevel => 'full', # small DB, no point in medium?
	}, $class;
}

sub _begin_txn ($) {
	my ($self) = @_;
	my $wdb = $PublicInbox::Search::X{WritableDatabase};
	my $xdb = eval { $wdb->new($self->{mi_dir}, $self->{flags}) };
	croak "Failed opening $self->{mi_dir}: $@" if $@;
	$xdb->begin_transaction;
	$xdb;
}

sub commit_txn {
	my ($self) = @_;
	my $xdb = delete $self->{xdb} or return;
	$xdb->commit_transaction;
}

sub create_xdb {
	my ($self) = @_;
	$self->{xdb} //= _begin_txn($self);
	commit_txn($self);
}

sub remove_eidx_key {
	my ($self, $eidx_key) = @_;
	my $xdb = $self->{xdb} //= _begin_txn($self);
	my $head = $xdb->postlist_begin('Q'.$eidx_key);
	my $tail = $xdb->postlist_end('Q'.$eidx_key);
	my @docids; # only one, unless we had bugs
	for (; $head != $tail; $head++) {
		push @docids, $head->get_docid;
	}
	for my $docid (@docids) {
		$xdb->delete_document($docid);
		warn "I: remove inbox docid #$docid ($eidx_key)\n";
	}
}

# adds or updates according to $eidx_key
sub index_ibx {
	my ($self, $ibx) = @_;
	my $eidx_key = $ibx->eidx_key;
	my $xdb = $self->{xdb} //= _begin_txn($self);
	# Q = uniQue in Xapian terminology
	my $head = $xdb->postlist_begin('Q'.$eidx_key);
	my $tail = $xdb->postlist_end('Q'.$eidx_key);
	my ($docid, @drop);
	for (; $head != $tail; $head++) {
		if (defined $docid) {
			my $i = $head->get_docid;
			push @drop, $i;
			warn <<EOF;
W: multiple inboxes keyed to `$eidx_key', deleting #$i
EOF
		} else {
			$docid = $head->get_docid;
		}
	}
	$xdb->delete_document($_) for @drop; # just in case

	my $doc = $PublicInbox::Search::X{Document}->new;
	term_generator($self)->set_document($doc);

	# allow sorting by modified and uidvalidity (created at)
	add_val($doc, $PublicInbox::MiscSearch::MODIFIED, $ibx->modified);
	add_val($doc, $PublicInbox::MiscSearch::UIDVALIDITY, $ibx->uidvalidity);

	$doc->add_boolean_term('Q'.$eidx_key); # uniQue id
	$doc->add_boolean_term('T'.'inbox'); # Type

	# force reread from disk, {description} could be loaded from {misc}
	delete @$ibx{qw(-art_min -art_max description)};
	if (defined($ibx->{newsgroup}) && $ibx->nntp_usable) {
		$doc->add_boolean_term('T'.'newsgroup'); # additional Type
		my $n = $ibx->art_min;
		add_val($doc, $PublicInbox::MiscSearch::ART_MIN, $n) if $n;
		$n = $ibx->art_max;
		add_val($doc, $PublicInbox::MiscSearch::ART_MAX, $n) if $n;
	}

	my $desc = $ibx->description;

	# description = S/Subject (or title)
	# address = A/Author
	index_text($self, $desc, 1, 'S');
	index_text($self, $ibx->{name}, 1, 'XNAME');
	my %map = (
		address => 'A',
		listid => 'XLISTID',
		infourl => 'XINFOURL',
		url => 'XURL'
	);
	while (my ($f, $pfx) = each %map) {
		for my $v (@{$ibx->{$f} // []}) {
			index_text($self, $v, 1, $pfx);
		}
	}
	my $data = {};
	if (defined(my $max = $ibx->max_git_epoch)) { # v2
		my $pfx = "/$ibx->{name}/git/";
		for my $epoch (0..$max) {
			my $git = $ibx->git_epoch($epoch) or return;
			if (my $ent = $git->manifest_entry($epoch, $desc)) {
				$data->{"$pfx$epoch.git"} = $ent;
				$ent->{git_dir} = $git->{git_dir};
			}
			$git->cleanup; # ->modified starts cat-file --batch
		}
	} elsif (my $ent = $ibx->git->manifest_entry) { # v1
		$ent->{git_dir} = $ibx->{inboxdir};
		$data->{"/$ibx->{name}"} = $ent;
	}
	$doc->set_data($json->encode($data));
	if (defined $docid) {
		$xdb->replace_document($docid, $doc);
	} else {
		$xdb->add_document($doc);
	}
}

1;
