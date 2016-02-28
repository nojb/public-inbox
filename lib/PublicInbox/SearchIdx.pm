# Copyright (C) 2015 all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
# based on notmuch, but with no concept of folders, files or flags
#
# Indexes mail with Xapian and our (SQLite-based) ::Msgmap for use
# with the web and NNTP interfaces.  This index maintains thread
# relationships for use by Mail::Thread.  This writes to the search
# index.
package PublicInbox::SearchIdx;
use strict;
use warnings;
use base qw(PublicInbox::Search);
use PublicInbox::MID qw/mid_clean id_compress/;
require PublicInbox::Git;
*xpfx = *PublicInbox::Search::xpfx;

use constant MAX_MID_SIZE => 244; # max term size - 1 in Xapian
use constant {
	PERM_UMASK => 0,
	OLD_PERM_GROUP => 1,
	OLD_PERM_EVERYBODY => 2,
	PERM_GROUP => 0660,
	PERM_EVERYBODY => 0664,
};

sub new {
	my ($class, $git_dir, $writable) = @_;
	my $dir = $class->xdir($git_dir);
	require Search::Xapian::WritableDatabase;
	my $flag = Search::Xapian::DB_OPEN;
	my $self = bless { git_dir => $git_dir }, $class;
	my $perm = $self->_git_config_perm;
	my $umask = _umask_for($perm);
	$self->{umask} = $umask;
	$self->{xdb} = $self->with_umask(sub {
		if ($writable == 1) {
			require File::Path;
			File::Path::mkpath($dir);
			$flag = Search::Xapian::DB_CREATE_OR_OPEN;
		}
		Search::Xapian::WritableDatabase->new($dir, $flag);
	});
	$self;
}

sub add_val {
	my ($doc, $col, $num) = @_;
	$num = Search::Xapian::sortable_serialise($num);
	$doc->add_value($col, $num);
}

sub add_message {
	my ($self, $mime, $bytes, $num) = @_; # mime = Email::MIME object
	my $db = $self->{xdb};

	my $doc_id;
	my $mid = mid_clean($mime->header('Message-ID'));
	my $was_ghost = 0;
	my $ct_msg = $mime->header('Content-Type') || 'text/plain';

	eval {
		die 'Message-ID too long' if length($mid) > MAX_MID_SIZE;
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

		if ($subj ne '') {
			my $path = $self->subject_path($subj);
			$doc->add_term(xpfx('path') . id_compress($path));
		}

		add_val($doc, &PublicInbox::Search::TS, $smsg->ts);

		defined($num) and
			add_val($doc, &PublicInbox::Search::NUM, $num);

		defined($bytes) and
			add_val($doc, &PublicInbox::Search::BYTES, $bytes);

		add_val($doc, &PublicInbox::Search::LINES,
				$mime->body_raw =~ tr!\n!\n!);

		my $tg = $self->term_generator;

		$tg->set_document($doc);
		$tg->index_text($subj, 1, 'S') if $subj;
		$tg->increase_termpos;
		$tg->index_text($subj) if $subj;
		$tg->increase_termpos;

		$tg->index_text($smsg->from);
		$tg->increase_termpos;

		$mime->walk_parts(sub {
			my ($part) = @_;
			return if $part->subparts; # walk_parts already recurses
			my $ct = $part->content_type || $ct_msg;

			# account for filter bugs...
			$ct =~ m!\btext/plain\b!i or return;

			my (@orig, @quot);
			my $body = $part->body;
			$part->body_set('');
			my @lines = split(/\n/, $body);
			while (defined(my $l = shift @lines)) {
				if ($l =~ /^\s*>/) {
					push @quot, $l;
				} else {
					push @orig, $l;
				}
			}
			if (@quot) {
				$tg->index_text(join("\n", @quot), 0);
				@quot = ();
				$tg->increase_termpos;
			}
			if (@orig) {
				$tg->index_text(join("\n", @orig));
				@orig = ();
				$tg->increase_termpos;
			}
		});

		if ($was_ghost) {
			$doc_id = $smsg->doc_id;
			$self->link_message($smsg, 0);
			$doc->set_data($smsg->to_doc_data);
			$db->replace_document($doc_id, $doc);
		} else {
			$self->link_message($smsg, 0);
			$doc->set_data($smsg->to_doc_data);
			$doc_id = $db->add_document($doc);
		}
	};

	if ($@) {
		warn "failed to index message <$mid>: $@\n";
		return undef;
	}
	$doc_id;
}

# returns deleted doc_id on success, undef on missing
sub remove_message {
	my ($self, $mid) = @_;
	my $db = $self->{xdb};
	my $doc_id;
	$mid = mid_clean($mid);

	eval {
		$doc_id = $self->find_unique_doc_id('mid', $mid);
		$db->delete_document($doc_id) if defined $doc_id;
	};

	if ($@) {
		warn "failed to remove message <$mid>: $@\n";
		return undef;
	}
	$doc_id;
}

sub term_generator { # write-only
	my ($self) = @_;

	my $tg = $self->{term_generator};
	return $tg if $tg;

	$tg = Search::Xapian::TermGenerator->new;
	$tg->set_stemmer($self->stemmer);

	$self->{term_generator} = $tg;
}

# increments last_thread_id counter
# returns a 64-bit integer represented as a hex string
sub next_thread_id {
	my ($self) = @_;
	my $db = $self->{xdb};
	my $last_thread_id = int($db->get_metadata('last_thread_id') || 0);

	$db->set_metadata('last_thread_id', ++$last_thread_id);

	$last_thread_id;
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
	my $mid = $smsg->mid;
	my $mime = $smsg->mime;
	my $refs = $mime->header('References');
	my @refs = $refs ? ($refs =~ /<([^>]+)>/g) : ();
	if (my $irt = $mime->header('In-Reply-To')) {
		# last References should be $irt
		# we will de-dupe later
		push @refs, mid_clean($irt);
	}

	my $tid;
	if (@refs) {
		my %uniq = ($mid => 1);
		my @orig_refs = @refs;
		@refs = ();

		# prevent circular references via References: here:
		foreach my $ref (@orig_refs) {
			if (length($ref) > MAX_MID_SIZE) {
				warn "References: <$ref> too long, ignoring\n";
			}
			next if $uniq{$ref};
			$uniq{$ref} = 1;
			push @refs, $ref;
		}
	}
	if (@refs) {
		$smsg->{references} = '<'.join('> <', @refs).'>';

		# first ref *should* be the thread root,
		# but we can never trust clients to do the right thing
		my $ref = shift @refs;
		$tid = $self->_resolve_mid_to_tid($ref);

		# the rest of the refs should point to this tid:
		foreach $ref (@refs) {
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

sub index_blob {
	my ($self, $git, $mime, $bytes, $num) = @_;
	$self->add_message($mime, $bytes, $num);
}

sub unindex_blob {
	my ($self, $git, $mime) = @_;
	my $mid = mid_clean($mime->header('Message-ID'));
	$self->remove_message($mid) if defined $mid;
}

sub index_mm {
	my ($self, $git, $mime) = @_;
	$self->{mm}->mid_insert(mid_clean($mime->header('Message-ID')));
}

sub unindex_mm {
	my ($self, $git, $mime) = @_;
	$self->{mm}->mid_delete(mid_clean($mime->header('Message-ID')));
}

sub index_mm2 {
	my ($self, $git, $mime, $bytes) = @_;
	my $num = $self->{mm}->num_for(mid_clean($mime->header('Message-ID')));
	index_blob($self, $git, $mime, $bytes, $num);
}

sub unindex_mm2 {
	my ($self, $git, $mime) = @_;
	$self->{mm}->mid_delete(mid_clean($mime->header('Message-ID')));
	unindex_blob($self, $git, $mime);
}

sub index_both {
	my ($self, $git, $mime, $bytes) = @_;
	my $num = index_mm($self, $git, $mime);
	index_blob($self, $git, $mime, $bytes, $num);
}

sub unindex_both {
	my ($self, $git, $mime) = @_;
	unindex_blob($self, $git, $mime);
	unindex_mm($self, $git, $mime);
}

sub do_cat_mail {
	my ($git, $blob, $sizeref) = @_;
	my $mime = eval {
		my $str = $git->cat_file($blob, $sizeref);
		Email::MIME->new($str);
	};
	$@ ? undef : $mime;
}

sub index_sync {
	my ($self, $head) = @_;
	$self->with_umask(sub { $self->_index_sync($head) });
}

sub rlog {
	my ($self, $range, $add_cb, $del_cb) = @_;
	my $hex = '[a-f0-9]';
	my $h40 = $hex .'{40}';
	my $addmsg = qr!^:000000 100644 \S+ ($h40) A\t${hex}{2}/${hex}{38}$!;
	my $delmsg = qr!^:100644 000000 ($h40) \S+ D\t${hex}{2}/${hex}{38}$!;
	my $git = PublicInbox::Git->new($self->{git_dir});
	my $log = $git->popen(qw/log --reverse --no-notes --no-color
				--raw -r --no-abbrev/, $range);
	my $latest;
	my $bytes;
	while (defined(my $line = <$log>)) {
		if ($line =~ /$addmsg/o) {
			my $mime = do_cat_mail($git, $1, \$bytes) or next;
			$add_cb->($self, $git, $mime, $bytes);
		} elsif ($line =~ /$delmsg/o) {
			my $mime = do_cat_mail($git, $1) or next;
			$del_cb->($self, $git, $mime);
		} elsif ($line =~ /^commit ($h40)/o) {
			$latest = $1;
		}
	}
	$latest;
}

# indexes all unindexed messages
sub _index_sync {
	my ($self, $head) = @_;
	my $db = $self->{xdb};
	$head ||= 'HEAD';
	my $mm = $self->{mm} = eval {
		require PublicInbox::Msgmap;
		PublicInbox::Msgmap->new($self->{git_dir}, 1);
	};

	$db->begin_transaction;
	my $lx = $db->get_metadata('last_commit');
	my $range = $lx eq '' ? $head : "$lx..$head";
	if ($mm) {
		$mm->{dbh}->begin_work;
		my $lm = $mm->last_commit || '';
		if ($lm eq $lx) {
			# Common case is the indexes are synced,
			# we only need to run git-log once:
			$lx = $self->rlog($range, *index_both, *unindex_both);
			$mm->{dbh}->commit;
			if (defined $lx) {
				$db->set_metadata('last_commit', $lx);
				$mm->last_commit($lx);
			}
		} else {
			# dumb case, msgmap and xapian are out-of-sync
			# do not care for performance:
			my $r = $lm eq '' ? $head : "$lm..$head";
			$lm = $self->rlog($r, *index_mm, *unindex_mm);
			$mm->{dbh}->commit;
			$mm->last_commit($lm) if defined $lm;

			$lx = $self->rlog($range, *index_mm2, *unindex_mm2);
			$db->set_metadata('last_commit', $lx) if defined $lx;
		}
	} else {
		# user didn't install DBD::SQLite and DBI
		$lx = $self->rlog($range, *index_blob, *unindex_blob);
		$db->set_metadata('last_commit', $lx) if defined $lx;
	}
	if ($@) {
		$db->cancel_transaction;
		$mm->{dbh}->rollback if $mm;
	} else {
		$db->commit_transaction;
	}
}

# this will create a ghost as necessary
sub _resolve_mid_to_tid {
	my ($self, $mid) = @_;

	my $smsg = $self->lookup_message($mid) || $self->create_ghost($mid);
	$smsg->thread_id;
}

sub create_ghost {
	my ($self, $mid, $tid) = @_;

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

sub _read_git_config_perm {
	my ($self) = @_;
	my @cmd = qw(config core.sharedRepository);
	my $fh = PublicInbox::Git->new($self->{git_dir})->popen(@cmd);
	my $perm = <$fh>;
	chomp $perm if defined $perm;
	$perm;
}

sub _git_config_perm {
	my $self = shift;
	my $perm = scalar @_ ? $_[0] : _read_git_config_perm($self);
	return PERM_GROUP if (!defined($perm) || $perm eq '');
	return PERM_UMASK if ($perm eq 'umask');
	return PERM_GROUP if ($perm eq 'group');
	if ($perm =~ /\A(?:all|world|everybody)\z/) {
		return PERM_EVERYBODY;
	}
	return PERM_GROUP if ($perm =~ /\A(?:true|yes|on|1)\z/);
	return PERM_UMASK if ($perm =~ /\A(?:false|no|off|0)\z/);

	my $i = oct($perm);
	return PERM_UMASK if ($i == PERM_UMASK);
	return PERM_GROUP if ($i == OLD_PERM_GROUP);
	return PERM_EVERYBODY if ($i == OLD_PERM_EVERYBODY);

	if (($i & 0600) != 0600) {
		die "core.sharedRepository mode invalid: ".
		    sprintf('%.3o', $i) . "\nOwner must have permissions\n";
	}
	($i & 0666);
}

sub _umask_for {
	my ($perm) = @_; # _git_config_perm return value
	my $rv = $perm;
	return umask if $rv == 0;

	# set +x bit if +r or +w were set
	$rv |= 0100 if ($rv & 0600);
	$rv |= 0010 if ($rv & 0060);
	$rv |= 0001 if ($rv & 0006);
	(~$rv & 0777);
}

sub with_umask {
	my ($self, $cb) = @_;
	my $old = umask $self->{umask};
	my $rv = eval { $cb->() };
	my $err = $@;
	umask $old;
	die $err if $@;
	$rv;
}

1;
