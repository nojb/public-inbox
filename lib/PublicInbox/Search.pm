# Copyright (C) 2015, all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
# based on notmuch, but with no concept of folders, files or flags
package PublicInbox::Search;
use strict;
use warnings;
use PublicInbox::SearchMsg;
use Search::Xapian qw/:standard/;
require PublicInbox::View;
use Email::MIME;
use PublicInbox::MID qw/mid_clean mid_compressed/;

# This is English-only, everything else is non-standard and may be confused as
# a prefix common in patch emails
our $REPLY_RE = qr/^re:\s+/i;
our $LANG = 'english';

use constant {
	TS => 0,
	# SCHEMA_VERSION history
	# 0 - initial
	# 1 - subject_path is lower-cased
	# 2 - subject_path is mid_compressed in the index, only
	# 3 - message-ID is compressed if it includes '%' (hack!)
	# 4 - change "Re: " normalization, avoid circular Reference ghosts
	SCHEMA_VERSION => 4,
	QP_FLAGS => FLAG_PHRASE|FLAG_BOOLEAN|FLAG_LOVEHATE|FLAG_WILDCARD,
};

# setup prefixes
my %bool_pfx_internal = (
	type => 'T', # "mail" or "ghost"
	mid => 'Q', # uniQue id (Message-ID or mid_compressed)
);

my %bool_pfx_external = (
	path => 'XPATH',
	thread => 'G', # newsGroup (or similar entity - e.g. a web forum name)
	references => 'XREFS',
	inreplyto => 'XIRT',
);

my %prob_prefix = (
	subject => 'S',
);

my %all_pfx = (%bool_pfx_internal, %bool_pfx_external, %prob_prefix);

sub xpfx { $all_pfx{$_[0]} }

our %PFX2TERM_RMAP;
while (my ($k, $v) = each %all_pfx) {
	next if $prob_prefix{$k};
	$PFX2TERM_RMAP{$v} = $k;
}

my $mail_query = Search::Xapian::Query->new(xpfx('type') . 'mail');

sub new {
	my ($class, $git_dir, $writable) = @_;
	# allow concurrent versions for easier rollback:
	my $dir = "$git_dir/public-inbox/xapian" . SCHEMA_VERSION;
	my $db;

	if ($writable) { # not used by the WWW interface
		require Search::Xapian::WritableDatabase;
		my $flag = Search::Xapian::DB_OPEN;
		if ($writable == 1) {
			require File::Path;
			File::Path::mkpath($dir);
			$flag = Search::Xapian::DB_CREATE_OR_OPEN;
		}
		$db = Search::Xapian::WritableDatabase->new($dir, $flag);
	} else {
		$db = Search::Xapian::Database->new($dir);
	}
	bless { xdb => $db, git_dir => $git_dir }, $class;
}

sub reopen { $_[0]->{xdb}->reopen }

sub add_message {
	my ($self, $mime) = @_; # mime = Email::MIME object
	my $db = $self->{xdb};

	my $doc_id;
	my $mid_orig = mid_clean($mime->header_obj->header_raw('Message-ID'));
	my $mid = mid_compressed($mid_orig);
	my $was_ghost = 0;
	my $ct_msg = $mime->header('Content-Type') || 'text/plain';
	my $enc_msg = PublicInbox::View::enc_for($ct_msg);

	eval {
		my $smsg = $self->lookup_message($mid);
		my $doc;

		if ($smsg) {
			$smsg->ensure_metadata;
			# convert a ghost to a regular message
			# it will also clobber any existing regular message
			$smsg->mime($mime);
			$doc = $smsg->{doc};

			my $type = xpfx('type');
			eval {
				$doc->remove_term($type . 'ghost');
				$was_ghost = 1;
			};

			# probably does not exist:
			eval { $doc->remove_term($type . 'mail') };
			$doc->add_term($type . 'mail');
		}  else {
			$smsg = PublicInbox::SearchMsg->new($mime);
			$doc = $smsg->{doc};
			$doc->add_term(xpfx('mid') . $mid);
		}

		my $subj = $smsg->subject;

		if (length $subj) {
			$doc->add_term(xpfx('subject') . $subj);

			my $path = subject_path($subj);
			$doc->add_term(xpfx('path') . mid_compressed($path));
		}

		my $from = $smsg->from_name;
		my $date = $smsg->date;
		my $ts = Search::Xapian::sortable_serialise($smsg->ts);
		$doc->add_value(PublicInbox::Search::TS, $ts);

		$doc->set_data($smsg->to_doc_data);

		my $tg = $self->term_generator;

		$tg->set_document($doc);
		$tg->index_text($subj, 1, 'S') if $subj;
		$tg->increase_termpos;
		$tg->index_text($subj) if $subj;
		$tg->increase_termpos;

		$tg->index_text($smsg->from->format);
		$tg->increase_termpos;

		$mime->walk_parts(sub {
			my ($part) = @_;
			return if $part->subparts; # walk_parts already recurses
			my $ct = $part->content_type || $ct_msg;

			# account for filter bugs...
			$ct =~ m!\btext/plain\b!i or return;

			my $enc = PublicInbox::View::enc_for($ct, $enc_msg);
			my (@orig, @quot);
			foreach my $l (split(/\n/, $enc->decode($part->body))) {
				if ($l =~ /^\s*>/) {
					push @quot, $l;
				} else {
					push @orig, $l;
				}
			}
			if (@quot) {
				$tg->index_text(join("\n", @quot), 0);
				$tg->increase_termpos;
			}
			if (@orig) {
				$tg->index_text(join("\n", @orig));
				$tg->increase_termpos;
			}
		});

		if ($was_ghost) {
			$doc_id = $smsg->doc_id;
			$self->link_message($smsg, 0);
			$db->replace_document($doc_id, $doc);
		} else {
			$self->link_message($smsg, 0);
			$doc_id = $db->add_document($doc);
		}
	};

	if ($@) {
		warn "failed to index message <$mid_orig>: $@\n";
		return undef;
	}
	$doc_id;
}

# returns deleted doc_id on success, undef on missing
sub remove_message {
	my ($self, $mid_orig) = @_;
	my $db = $self->{xdb};
	my $doc_id;
	$mid_orig = mid_clean($mid_orig);
	my $mid = mid_compressed($mid_orig);

	eval {
		$doc_id = $self->find_unique_doc_id('mid', $mid);
		$db->delete_document($doc_id) if defined $doc_id;
	};

	if ($@) {
		warn "failed to remove message <$mid_orig>: $@\n";
		return undef;
	}
	$doc_id;
}

# read-only
sub query {
	my ($self, $query_string, $opts) = @_;
	my $query = $self->qp->parse_query($query_string, QP_FLAGS);

	$query = Search::Xapian::Query->new(OP_AND, $mail_query, $query);
	$self->do_enquire($query, $opts);
}

sub get_subject_path {
	my ($self, $path, $opts) = @_;
	my $query = $self->qp->parse_query("path:".mid_compressed($path), 0);
	$self->do_enquire($query);
}

# given a message ID, get followups to a message
sub get_followups {
	my ($self, $mid, $opts) = @_;
	$mid = mid_clean($mid);
	$mid = mid_compressed($mid);
	my $qp = $self->qp;
	my $irt = $qp->parse_query("inreplyto:$mid", 0);
	my $ref = $qp->parse_query("references:$mid", 0);
	my $query = Search::Xapian::Query->new(OP_OR, $irt, $ref);

	$self->do_enquire($query);
}

sub get_thread {
	my ($self, $mid, $opts) = @_;
	my $smsg = eval { $self->lookup_message($mid) };

	return { count => 0, msgs => [] } unless $smsg;
	my $qp = $self->qp;
	my $qtid = $qp->parse_query('thread:'.$smsg->thread_id);
	my $qsub = $qp->parse_query('path:'.mid_compressed($smsg->path));
	my $query = Search::Xapian::Query->new(OP_OR, $qtid, $qsub);
	$self->do_enquire($query);
}

# private subs below

sub do_enquire {
	my ($self, $query, $opts) = @_;
	my $enquire = $self->enquire;

	$enquire->set_query($query);
	$enquire->set_sort_by_relevance_then_value(TS, 0);
	$opts ||= {};
	my $offset = $opts->{offset} || 0;
	my $limit = $opts->{limit} || 50;
	my $mset = $enquire->get_mset($offset, $limit);
	my @msgs = map {
		PublicInbox::SearchMsg->load_doc($_->get_document);
	} $mset->items;

	{ count => $mset->get_matches_estimated, msgs => \@msgs }
}

# read-write
sub stemmer { Search::Xapian::Stem->new($LANG) }

# read-only
sub qp {
	my ($self) = @_;

	my $qp = $self->{query_parser};
	return $qp if $qp;

	# new parser
	$qp = Search::Xapian::QueryParser->new;
	$qp->set_default_op(OP_AND);
	$qp->set_database($self->{xdb});
	$qp->set_stemmer($self->stemmer);
	$qp->set_stemming_strategy(STEM_SOME);
	$qp->add_valuerangeprocessor($self->ts_range_processor);
	$qp->add_valuerangeprocessor($self->date_range_processor);

	while (my ($name, $prefix) = each %bool_pfx_external) {
		$qp->add_boolean_prefix($name, $prefix);
	}

	while (my ($name, $prefix) = each %prob_prefix) {
		$qp->add_prefix($name, $prefix);
	}

	$self->{query_parser} = $qp;
}

sub term_generator { # write-only
	my ($self) = @_;

	my $tg = $self->{term_generator};
	return $tg if $tg;

	$tg = Search::Xapian::TermGenerator->new;
	$tg->set_stemmer($self->stemmer);

	$self->{term_generator} = $tg;
}

sub next_doc_id { $_[0]->{xdb}->get_lastdocid + 1 }

# increments last_thread_id counter
# returns a 64-bit integer represented as a hex string
sub next_thread_id {
	my ($self) = @_;
	my $db = $self->{xdb};
	my $last_thread_id = int($db->get_metadata('last_thread_id') || 0);

	$db->set_metadata('last_thread_id', ++$last_thread_id);

	$last_thread_id;
}

sub ts_range_processor {
	$_[0]->{tsrp} ||= Search::Xapian::NumberValueRangeProcessor->new(TS);
}

sub date_range_processor {
	$_[0]->{drp} ||= Search::Xapian::DateValueRangeProcessor->new(TS);
}

sub link_message {
	my ($self, $smsg, $is_ghost) = @_;

	if ($is_ghost) {
		$smsg->ensure_metadata;
	} else {
		$self->link_message_to_parents($smsg);
	}
}

sub link_message_to_parents {
	my ($self, $smsg) = @_;
	my $doc = $smsg->{doc};
	my $mid = mid_compressed($smsg->mid);
	my $mime = $smsg->mime;
	my $refs = $mime->header_obj->header_raw('References');
	my @refs = $refs ? ($refs =~ /<([^>]+)>/g) : ();
	my $irt = $mime->header_obj->header_raw('In-Reply-To');
	if ($irt) {
		if ($irt =~ /<([^>]+)>/) {
			$irt = $1;
		}

		# maybe some crazies will try to make a circular reference:
		if ($irt eq $mid) {
			$irt = undef;
		} else {
			push @refs, $irt;
		}
	}

	my $tid;
	if (@refs) {
		my @crefs = map { mid_compressed($_) } @refs;
		my %uniq = ($mid => 1);

		# prevent circular references via References: here:
		@refs = ();
		foreach my $ref (@crefs) {
			next if $uniq{$ref};
			$uniq{$ref} = 1;
			push @refs, $ref;
		}
		$irt = undef if (defined $irt && !$uniq{$irt});
	}
	if (@refs) {
		if (defined $irt) {
			$doc->add_term(xpfx('inreplyto') . $irt);
		}

		my $ref_pfx = xpfx('references');

		# first ref *should* be the thread root,
		# but we can never trust clients to do the right thing
		my $ref = shift @refs;
		$doc->add_term($ref_pfx . $ref);
		$tid = $self->_resolve_mid_to_tid($ref);

		# the rest of the refs should point to this tid:
		foreach $ref (@refs) {
			$doc->add_term($ref_pfx . $ref);
			my $ptid = $self->_resolve_mid_to_tid($ref);
			if ($tid ne $ptid) {
				$self->merge_threads($tid, $ptid);
			}
		}
	} else {
		$tid = $self->next_thread_id;
	}
	$doc->add_term(xpfx('thread') . $tid);
}

sub lookup_message {
	my ($self, $mid) = @_;
	$mid = mid_clean($mid);
	$mid = mid_compressed($mid);

	my $doc_id = $self->find_unique_doc_id('mid', $mid);
	my $smsg;
	if (defined $doc_id) {
		# raises on error:
		my $doc = $self->{xdb}->get_document($doc_id);
		$smsg = PublicInbox::SearchMsg->wrap($doc, $mid);
		$smsg->doc_id($doc_id);
	}
	$smsg;
}

sub find_unique_doc_id {
	my ($self, $term, $value) = @_;

	my ($begin, $end) = $self->find_doc_ids($term, $value);

	return undef if $begin->equal($end); # not found

	my $rv = $begin->get_docid;

	# sanity check
	$begin->inc;
	$begin->equal($end) or die "Term '$term:$value' is not unique\n";
	$rv;
}

# returns begin and end PostingIterator
sub find_doc_ids {
	my ($self, $term, $value) = @_;

	$self->find_doc_ids_for_term(xpfx($term) . $value);
}

# returns begin and end PostingIterator
sub find_doc_ids_for_term {
	my ($self, $term) = @_;
	my $db = $self->{xdb};

	($db->postlist_begin($term), $db->postlist_end($term));
}

# this will create a ghost as necessary
sub _resolve_mid_to_tid {
	my ($self, $mid) = @_;

	my $smsg = $self->lookup_message($mid) || $self->create_ghost($mid);
	$smsg->thread_id;
}

sub create_ghost {
	my ($self, $mid, $tid) = @_;

	$mid = mid_compressed($mid);
	$tid = $self->next_thread_id unless defined $tid;

	my $doc = Search::Xapian::Document->new;
	$doc->add_term(xpfx('mid') . $mid);
	$doc->add_term(xpfx('thread') . $tid);
	$doc->add_term(xpfx('type') . 'ghost');

	my $smsg = PublicInbox::SearchMsg->wrap($doc, $mid);
	$self->link_message($smsg, 1);
	$self->{xdb}->add_document($doc);

	$smsg;
}

sub merge_threads {
	my ($self, $winner_tid, $loser_tid) = @_;
	my ($head, $tail) = $self->find_doc_ids('thread', $loser_tid);
	my $thread_pfx = xpfx('thread');
	my $db = $self->{xdb};

	for (; $head != $tail; $head->inc) {
		my $docid = $head->get_docid;
		my $doc = $db->get_document($docid);
		$doc->remove_term($thread_pfx . $loser_tid);
		$doc->add_term($thread_pfx . $winner_tid);
		$db->replace_document($docid, $doc);
	}
}

# normalize subjects so they are suitable as pathnames for URLs
sub subject_path {
	my $subj = pop;
	$subj = subject_normalized($subj);
	$subj =~ s![^a-zA-Z0-9_\.~/\-]+!_!g;
	lc($subj);
}

sub subject_normalized {
	my $subj = pop;
	$subj =~ s/\A\s+//s; # no leading space
	$subj =~ s/\s+\z//s; # no trailing space
	$subj =~ s/\s+/ /gs; # no redundant spaces
	$subj =~ s/\.+\z//; # no trailing '.'
	$subj =~ s/$REPLY_RE//igo; # remove reply prefix
	$subj;
}

sub do_cat_mail {
	my ($git, $blob) = @_;
	my $mime = eval {
		my $str = $git->cat_file($blob);
		Email::MIME->new($str);
	};
	$@ ? undef : $mime;
}

sub index_blob {
	my ($self, $git, $blob) = @_;
	my $mime = do_cat_mail($git, $blob) or return;
	eval { $self->add_message($mime) };
	warn "W: index_blob $blob: $@\n" if $@;
}

sub unindex_blob {
	my ($self, $git, $blob) = @_;
	my $mime = do_cat_mail($git, $blob) or return;
	my $mid = $mime->header_obj->header_raw('Message-ID');
	eval { $self->remove_message($mid) } if defined $mid;
	warn "W: unindex_blob $blob: $@\n" if $@;
}

sub enquire {
	my ($self) = @_;
	$self->{enquire} ||= Search::Xapian::Enquire->new($self->{xdb});
}

# indexes all unindexed messages
sub index_sync {
	my ($self) = @_;
	require PublicInbox::GitCatFile;
	my $db = $self->{xdb};
	my $hex = '[a-f0-9]';
	my $h40 = $hex .'{40}';
	my $addmsg = qr!^:000000 100644 \S+ ($h40) A\t${hex}{2}/${hex}{38}$!;
	my $delmsg = qr!^:100644 000000 ($h40) \S+ D\t${hex}{2}/${hex}{38}$!;

	$db->begin_transaction;
	eval {
		my $git = PublicInbox::GitCatFile->new($self->{git_dir});

		my $latest = $db->get_metadata('last_commit');
		my $range = length $latest ? "$latest..HEAD" : 'HEAD';
		$latest = undef;

		# get indexed messages
		my @cmd = ('git', "--git-dir=$self->{git_dir}", "log",
			    qw/--reverse --no-notes --no-color --raw -r
			       --no-abbrev/, $range);
		my $pid = open(my $log, '-|', @cmd) or
			die('open` '.join(' ', @cmd) . " pipe failed: $!\n");

		while (my $line = <$log>) {
			if ($line =~ /$addmsg/o) {
				$self->index_blob($git, $1);
			} elsif ($line =~ /$delmsg/o) {
				$self->unindex_blob($git, $1);
			} elsif ($line =~ /^commit ($h40)/o) {
				$latest = $1;
			}
		}
		close $log;
		$db->set_metadata('last_commit', $latest) if defined $latest;
	};
	if ($@) {
		warn "indexing failed: $@\n";
		$db->cancel_transaction;
	} else {
		$db->commit_transaction;
	}
}

1;
