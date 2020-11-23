# Copyright (C) 2020 all contributors <meta@public-inbox.org>
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
use PublicInbox::Spawn qw(nodatacow_dir);
use Carp qw(croak);
use File::Path ();
use PublicInbox::MiscSearch;
use PublicInbox::Config;

sub new {
	my ($class, $eidx) = @_;
	PublicInbox::SearchIdx::load_xapian_writable();
	my $mi_dir = "$eidx->{xpfx}/misc";
	File::Path::mkpath($mi_dir);
	nodatacow_dir($mi_dir);
	my $flags = $PublicInbox::SearchIdx::DB_CREATE_OR_OPEN;
	$flags |= $PublicInbox::SearchIdx::DB_NO_SYNC if $eidx->{-no_fsync};
	bless {
		mi_dir => $mi_dir,
		flags => $flags,
		indexlevel => 'full', # small DB, no point in medium?
	}, $class;
}

sub begin_txn {
	my ($self) = @_;
	croak 'BUG: already in txn' if $self->{xdb}; # XXX make lazy?
	my $wdb = $PublicInbox::Search::X{WritableDatabase};
	my $xdb = eval { $wdb->new($self->{mi_dir}, $self->{flags}) };
	croak "Failed opening $self->{mi_dir}: $@" if $@;
	$self->{xdb} = $xdb;
	$xdb->begin_transaction;
}

sub commit_txn {
	my ($self) = @_;
	croak 'BUG: not in txn' unless $self->{xdb}; # XXX make lazy?
	delete($self->{xdb})->commit_transaction;
}

sub index_ibx {
	my ($self, $ibx) = @_;
	my $eidx_key = $ibx->eidx_key;
	my $xdb = $self->{xdb};
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

	# allow sorting by modified
	add_val($doc, $PublicInbox::MiscSearch::MODIFIED, $ibx->modified);

	$doc->add_boolean_term('Q'.$eidx_key);
	$doc->add_boolean_term('T'.'inbox');
	term_generator($self)->set_document($doc);

	# description = S/Subject (or title)
	# address = A/Author
	index_text($self, $ibx->description, 1, 'S');
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
	index_text($self, $ibx->{name}, 1, 'XNAME');
	my $data = {};
	if (defined(my $max = $ibx->max_git_epoch)) { # v2
		my $desc = $ibx->description;
		my $pfx = "/$ibx->{name}/git/";
		for my $epoch (0..$max) {
			my $git = $ibx->git_epoch($epoch) or return;
			if (my $ent = $git->manifest_entry($epoch, $desc)) {
				$data->{"$pfx$epoch.git"} = $ent;
			}
			$git->cleanup; # ->modified starts cat-file --batch
		}
	} elsif (my $ent = $ibx->git->manifest_entry) { # v1
		$data->{"/$ibx->{name}"} = $ent;
	}
	$doc->set_data(PublicInbox::Config::json()->encode($data));
	if (defined $docid) {
		$xdb->replace_document($docid, $doc);
	} else {
		$xdb->add_document($doc);
	}
}

1;
