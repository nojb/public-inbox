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
use Fcntl qw(:flock :DEFAULT);
use Email::MIME;
use Email::MIME::ContentType;
$Email::MIME::ContentType::STRICT_PARAMS = 0;
use base qw(PublicInbox::Search);
use PublicInbox::MID qw/mid_clean id_compress mid_mime/;
use PublicInbox::MsgIter;
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

# XXX temporary hack...
my $xap_ver = ((Search::Xapian::major_version << 16) |
		 (Search::Xapian::minor_version << 8 ) |
		  Search::Xapian::revision());
our $XAP_LOCK_BROKEN = $xap_ver >= 0x010216; # >= 1.2.22

sub new {
	my ($class, $git_dir, $writable) = @_;
	my $dir = PublicInbox::Search->xdir($git_dir);
	require Search::Xapian::WritableDatabase;
	my $flag = Search::Xapian::DB_OPEN;
	my $self = bless { git_dir => $git_dir }, $class;
	my $perm = $self->_git_config_perm;
	my $umask = _umask_for($perm);
	$self->{umask} = $umask;
	$self->{lock_path} = "$git_dir/ssoma.lock";
	$self->{xdb} = $self->with_umask(sub {
		if ($writable == 1) {
			require File::Path;
			File::Path::mkpath($dir);
			$self->{batch_size} = 100 unless $XAP_LOCK_BROKEN;
			$flag = Search::Xapian::DB_CREATE_OR_OPEN;
			_lock_acquire($self);
		}
		Search::Xapian::WritableDatabase->new($dir, $flag);
	});
	$self;
}

sub _xdb_release {
	my ($self) = @_;
	my $xdb = delete $self->{xdb};
	$xdb->commit_transaction;
	$xdb->close;
}

sub _xdb_acquire {
	my ($self, $more) = @_;
	my $dir = PublicInbox::Search->xdir($self->{git_dir});
	my $flag = Search::Xapian::DB_OPEN;
	my $xdb = Search::Xapian::WritableDatabase->new($dir, $flag);
	$xdb->begin_transaction if $more;
	$self->{xdb} = $xdb;
}

sub _lock_acquire {
	my ($self) = @_;
	sysopen(my $lockfh, $self->{lock_path}, O_WRONLY|O_CREAT) or
		die "failed to open lock $self->{lock_path}: $!\n";
	flock($lockfh, LOCK_EX) or die "lock failed: $!\n";
	$self->{lockfh} = $lockfh;
}

sub _lock_release {
	my ($self) = @_;
	my $lockfh = delete $self->{lockfh};
	flock($lockfh, LOCK_UN) or die "unlock failed: $!\n";
	close $lockfh or die "close failed: $!\n";
}

sub add_val {
	my ($doc, $col, $num) = @_;
	$num = Search::Xapian::sortable_serialise($num);
	$doc->add_value($col, $num);
}

sub add_message {
	my ($self, $mime, $bytes, $num, $blob) = @_; # mime = Email::MIME object
	my $db = $self->{xdb};

	my ($doc_id, $old_tid);
	my $mid = mid_clean(mid_mime($mime));
	my $ct_msg = $mime->header('Content-Type') || 'text/plain';

	eval {
		die 'Message-ID too long' if length($mid) > MAX_MID_SIZE;
		my $smsg = $self->lookup_message($mid);
		if ($smsg) {
			# convert a ghost to a regular message
			# it will also clobber any existing regular message
			$doc_id = $smsg->doc_id;
			$old_tid = $smsg->thread_id;
		}
		$smsg = PublicInbox::SearchMsg->new($mime);
		my $doc = $smsg->{doc};
		$doc->add_term(xpfx('mid') . $mid);

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

		msg_iter($mime, sub {
			my ($part, $depth, @idx) = @{$_[0]};
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

		link_message($self, $smsg, $old_tid);
		$doc->set_data($smsg->to_doc_data($blob));
		if (defined $doc_id) {
			$db->replace_document($doc_id, $doc);
		} else {
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
	my ($self, $smsg, $old_tid) = @_;
	my $doc = $smsg->{doc};
	my $mid = $smsg->mid;
	my $mime = $smsg->mime;
	my $hdr = $mime->header_obj;
	my $refs = $hdr->header_raw('References');
	my @refs = $refs ? ($refs =~ /<([^>]+)>/g) : ();
	if (my $irt = $hdr->header_raw('In-Reply-To')) {
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
		$self->merge_threads($tid, $old_tid) if defined $old_tid;

		# the rest of the refs should point to this tid:
		foreach $ref (@refs) {
			my $ptid = $self->_resolve_mid_to_tid($ref);
			merge_threads($self, $tid, $ptid);
		}
	} else {
		$tid = $self->next_thread_id;
	}
	$doc->add_term(xpfx('thread') . $tid);
}

sub index_blob {
	my ($self, $git, $mime, $bytes, $num, $blob) = @_;
	$self->add_message($mime, $bytes, $num, $blob);
}

sub unindex_blob {
	my ($self, $git, $mime) = @_;
	my $mid = eval { mid_clean(mid_mime($mime)) };
	$self->remove_message($mid) if defined $mid;
}

sub index_mm {
	my ($self, $git, $mime) = @_;
	$self->{mm}->mid_insert(mid_clean(mid_mime($mime)));
}

sub unindex_mm {
	my ($self, $git, $mime) = @_;
	$self->{mm}->mid_delete(mid_clean(mid_mime($mime)));
}

sub index_mm2 {
	my ($self, $git, $mime, $bytes, $blob) = @_;
	my $num = $self->{mm}->num_for(mid_clean(mid_mime($mime)));
	index_blob($self, $git, $mime, $bytes, $num, $blob);
}

sub unindex_mm2 {
	my ($self, $git, $mime) = @_;
	$self->{mm}->mid_delete(mid_clean(mid_mime($mime)));
	unindex_blob($self, $git, $mime);
}

sub index_both {
	my ($self, $git, $mime, $bytes, $blob) = @_;
	my $num = index_mm($self, $git, $mime);
	index_blob($self, $git, $mime, $bytes, $num, $blob);
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
		# fixup bugs from import:
		$$str =~ s/\A[\r\n]*From [^\r\n]*\r?\n//s;
		Email::MIME->new($str);
	};
	$@ ? undef : $mime;
}

sub index_sync {
	my ($self, $opts) = @_;
	with_umask($self, sub { $self->_index_sync($opts) });
}

sub rlog {
	my ($self, $range, $add_cb, $del_cb, $batch_cb) = @_;
	my $hex = '[a-f0-9]';
	my $h40 = $hex .'{40}';
	my $addmsg = qr!^:000000 100644 \S+ ($h40) A\t${hex}{2}/${hex}{38}$!;
	my $delmsg = qr!^:100644 000000 ($h40) \S+ D\t${hex}{2}/${hex}{38}$!;
	my $git = PublicInbox::Git->new($self->{git_dir});
	my $log = $git->popen(qw/log --reverse --no-notes --no-color
				--raw -r --no-abbrev/, $range);
	my $latest;
	my $bytes;
	my $max = $self->{batch_size}; # may be undef
	local $/ = "\n";
	my $line;
	while (defined($line = <$log>)) {
		if ($line =~ /$addmsg/o) {
			my $blob = $1;
			my $mime = do_cat_mail($git, $blob, \$bytes) or next;
			$add_cb->($self, $git, $mime, $bytes, $blob);
		} elsif ($line =~ /$delmsg/o) {
			my $blob = $1;
			my $mime = do_cat_mail($git, $blob) or next;
			$del_cb->($self, $git, $mime);
		} elsif ($line =~ /^commit ($h40)/o) {
			if (defined $max && --$max <= 0) {
				$max = $self->{batch_size};
				$batch_cb->($latest, 1);
			}
			$latest = $1;
		}
	}
	$batch_cb->($latest, 0);
}

# indexes all unindexed messages
sub _index_sync {
	my ($self, $opts) = @_;
	my $tip = $opts->{ref} || 'HEAD';
	my $mm = $self->{mm} = eval {
		require PublicInbox::Msgmap;
		PublicInbox::Msgmap->new($self->{git_dir}, 1);
	};
	my $xdb = $self->{xdb};
	$xdb->begin_transaction;
	my $reindex = $opts->{reindex};
	my $mkey = 'last_commit';
	my $last_commit = $xdb->get_metadata($mkey);
	my $lx = $last_commit;
	if ($reindex) {
		$lx = '';
		$mkey = undef if $last_commit ne '';
	}
	my $dbh;
	my $cb = sub {
		my ($commit, $more) = @_;
		$xdb->set_metadata($mkey, $commit) if $mkey && $commit;
		if ($dbh) {
			$mm->last_commit($commit) if $commit;
			$dbh->commit;
		}
		if ($XAP_LOCK_BROKEN) {
			$xdb->commit_transaction if !$more;
		} else {
			$xdb = undef;
			_xdb_release($self);
			_lock_release($self);
		}
		# let another process do some work...
		if (!$XAP_LOCK_BROKEN) {
			_lock_acquire($self);
			$dbh->begin_work if $dbh && $more;
			$xdb = _xdb_acquire($self, $more);
		}
	};

	my $range = $lx eq '' ? $tip : "$lx..$tip";
	if ($mm) {
		$dbh = $mm->{dbh};
		$dbh->begin_work;
		my $lm = $mm->last_commit || '';
		if ($lm eq $lx) {
			# Common case is the indexes are synced,
			# we only need to run git-log once:
			rlog($self, $range, *index_both, *unindex_both, $cb);
		} else {
			# Uncommon case, msgmap and xapian are out-of-sync
			# do not care for performance (but git is fast :>)
			# This happens if we have to reindex Xapian since
			# msgmap is a frozen format and our Xapian format
			# is evolving.
			my $r = $lm eq '' ? $tip : "$lm..$tip";

			# first, ensure msgmap is up-to-date:
			my $mkey_prev = $mkey;
			$mkey = undef; # ignore xapian, for now
			rlog($self, $r, *index_mm, *unindex_mm, $cb);

			# now deal with Xapian
			$mkey = $mkey_prev;
			$dbh = undef;
			rlog($self, $range, *index_mm2, *unindex_mm2, $cb);
		}
	} else {
		# user didn't install DBD::SQLite and DBI
		rlog($self, $range, *index_blob, *unindex_blob, $cb);
	}
}

# this will create a ghost as necessary
sub _resolve_mid_to_tid {
	my ($self, $mid) = @_;

	my $smsg = $self->lookup_message($mid) || $self->create_ghost($mid);
	$smsg->thread_id;
}

sub create_ghost {
	my ($self, $mid) = @_;

	my $tid = $self->next_thread_id;
	my $doc = Search::Xapian::Document->new;
	$doc->add_term(xpfx('mid') . $mid);
	$doc->add_term(xpfx('thread') . $tid);
	$doc->add_term(xpfx('type') . 'ghost');

	my $smsg = PublicInbox::SearchMsg->wrap($doc, $mid);
	$self->{xdb}->add_document($doc);

	$smsg;
}

sub merge_threads {
	my ($self, $winner_tid, $loser_tid) = @_;
	return if $winner_tid == $loser_tid;
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
	local $/ = "\n";
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

sub DESTROY {
	# order matters for unlocking
	$_[0]->{xdb} = undef;
	$_[0]->{lockfh} = undef;
}

1;
