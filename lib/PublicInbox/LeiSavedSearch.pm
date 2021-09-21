# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# pretends to be like LeiDedupe and also PublicInbox::Inbox
package PublicInbox::LeiSavedSearch;
use strict;
use v5.10.1;
use parent qw(PublicInbox::Lock);
use PublicInbox::Git;
use PublicInbox::OverIdx;
use PublicInbox::LeiSearch;
use PublicInbox::Config;
use PublicInbox::Spawn qw(run_die);
use PublicInbox::ContentHash qw(git_sha);
use PublicInbox::MID qw(mids_for_index);
use Digest::SHA qw(sha256_hex);
our $LOCAL_PFX = qr!\A(?:maildir|mh|mbox.+|mmdf|v2):!i; # TODO: put in LeiToMail?

# move this to PublicInbox::Config if other things use it:
my %cquote = ("\n" => '\\n', "\t" => '\\t', "\b" => '\\b');
sub cquote_val ($) { # cf. git-config(1)
	my ($val) = @_;
	$val =~ s/([\n\t\b])/$cquote{$1}/g;
	$val;
}

sub ARRAY_FIELDS () { qw(only include exclude) }
sub BOOL_FIELDS () {
	qw(external local remote import-remote import-before threads)
}

sub SINGLE_FIELDS () { qw(limit dedupe output) }

sub lss_dir_for ($$;$) {
	my ($lei, $dstref, $on_fs) = @_;
	my $pfx;
	if ($$dstref =~ m,\Aimaps?://,i) { # already canonicalized
		require PublicInbox::URIimap;
		my $uri = PublicInbox::URIimap->new($$dstref)->canonical;
		$$dstref = $$uri;
		$pfx = $uri->mailbox;
	} else {
		# can't use Cwd::abs_path since dirname($$dstref) may not exist
		$$dstref = $lei->rel2abs($$dstref);
		$$dstref =~ tr!/!/!s;
		$pfx = $$dstref;
	}
	($pfx) = ($pfx =~ m{([^/]+)/*\z}); # basename
	my $lss_dir = $lei->share_path . '/saved-searches/';
	my $d = "$lss_dir$pfx-".sha256_hex($$dstref);

	# fall-back to looking up by st_ino + st_dev in case we're in
	# a symlinked or bind-mounted path
	if ($on_fs && !-d $d && -e $$dstref) {
		my @cur = stat(_);
		my $want = pack('dd', @cur[1,0]); # st_ino + st_dev
		my ($c, $o, @st);
		for my $g ("$pfx-*", '*') {
			my @maybe = glob("$lss_dir$g/lei.saved-search");
			for my $f (@maybe) {
				$c = $lei->cfg_dump($f) // next;
				$o = $c->{'lei.q.output'} // next;
				$o =~ s!$LOCAL_PFX!! or next;
				@st = stat($o) or next;
				next if pack('dd', @st[1,0]) ne $want;
				$f =~ m!\A(.+?)/[^/]+\z! and return $1;
			}
		}
	}
	$d;
}

sub list {
	my ($lei, $pfx) = @_;
	my $lss_dir = $lei->share_path.'/saved-searches';
	return () unless -d $lss_dir;
	# TODO: persist the cache?  Use another format?
	my $f = $lei->cache_dir."/saved-tmp.$$.".time.'.config';
	open my $fh, '>', $f or die "open $f: $!";
	print $fh "[include]\n";
	for my $p (glob("$lss_dir/*/lei.saved-search")) {
		print $fh "\tpath = ", cquote_val($p), "\n";
	}
	close $fh or die "close $f: $!";
	my $cfg = $lei->cfg_dump($f);
	unlink($f);
	my $out = $cfg ? $cfg->get_all('lei.q.output') : [];
	map {;
		s!$LOCAL_PFX!!;
		$_;
	} @$out
}

sub translate_dedupe ($$) {
	my ($self, $lei) = @_;
	my $dd = $lei->{opt}->{dedupe} // 'content';
	return 1 if $dd eq 'content'; # the default
	return $self->{"-dedupe_$dd"} = 1 if ($dd eq 'oid' || $dd eq 'mid');
	$lei->fail("--dedupe=$dd requires --no-save");
}

sub up { # updating existing saved search via "lei up"
	my ($cls, $lei, $dst) = @_;
	my $f;
	my $self = bless { ale => $lei->ale }, $cls;
	my $dir = $dst;
	output2lssdir($self, $lei, \$dir, \$f) or
		return $lei->fail("--no-save was used with $dst cwd=".
					$lei->rel2abs('.'));
	$self->{-cfg} = $lei->cfg_dump($f) // return $lei->fail;
	$self->{-ovf} = "$dir/over.sqlite3";
	$self->{'-f'} = $f;
	$self->{lock_path} = "$self->{-f}.flock";
	$self;
}

sub new { # new saved search "lei q --save"
	my ($cls, $lei) = @_;
	my $self = bless { ale => $lei->ale }, $cls;
	require File::Path;
	my $dst = $lei->{ovv}->{dst};

	# canonicalize away relative paths into the config
	if ($lei->{ovv}->{fmt} eq 'maildir' &&
			$dst =~ m!(?:/*|\A)\.\.(?:/*|\z)! && !-d $dst) {
		File::Path::make_path($dst);
		$lei->{ovv}->{dst} = $dst = $lei->abs_path($dst);
	}
	my $dir = lss_dir_for($lei, \$dst);
	File::Path::make_path($dir); # raises on error
	$self->{-cfg} = {};
	my $f = $self->{'-f'} = "$dir/lei.saved-search";
	translate_dedupe($self, $lei) or return;
	open my $fh, '>', $f or return $lei->fail("open $f: $!");
	my $sq_dst = PublicInbox::Config::squote_maybe($dst);
	my $q = $lei->{mset_opt}->{q_raw} // die 'BUG: {q_raw} missing';
	if (ref $q) {
		$q = join("\n", map { "\tq = ".cquote_val($_) } @$q);
	} else {
		$q = "\tq = ".cquote_val($q);
	}
	$dst = "$lei->{ovv}->{fmt}:$dst" if $dst !~ m!\Aimaps?://!i;
	$lei->{opt}->{output} = $dst;
	print $fh <<EOM;
; to refresh with new results, run: lei up $sq_dst
; `maxuid' and `lastresult' lines are maintained by "lei up" for optimization
[lei]
$q
[lei "q"]
EOM
	for my $k (ARRAY_FIELDS) {
		my $ary = $lei->{opt}->{$k} // next;
		for my $x (@$ary) {
			print $fh "\t$k = ".cquote_val($x)."\n";
		}
	}
	for my $k (BOOL_FIELDS) {
		my $val = $lei->{opt}->{$k} // next;
		print $fh "\t$k = ".($val ? 1 : 0)."\n";
	}
	for my $k (SINGLE_FIELDS) {
		my $val = $lei->{opt}->{$k} // next;
		print $fh "\t$k = $val\n";
	}
	close($fh) or return $lei->fail("close $f: $!");
	$self->{lock_path} = "$self->{-f}.flock";
	$self->{-ovf} = "$dir/over.sqlite3";
	$self;
}

sub description { $_[0]->{qstr} } # for WWW

sub cfg_set { # called by LeiXSearch
	my ($self, @args) = @_;
	my $lk = $self->lock_for_scope; # git-config doesn't wait
	run_die([qw(git config -f), $self->{'-f'}, @args]);
}

# drop-in for LeiDedupe API
sub is_dup {
	my ($self, $eml, $smsg) = @_;
	my $oidx = $self->{oidx} // die 'BUG: no {oidx}';
	my $lk;
	if ($self->{-dedupe_mid}) {
		$lk //= $self->lock_for_scope_fast;
		for my $mid (@{mids_for_index($eml)}) {
			my ($id, $prv);
			return 1 if $oidx->next_by_mid($mid, \$id, \$prv);
		}
	}
	my $blob = $smsg ? $smsg->{blob} : git_sha(1, $eml)->hexdigest;
	$lk //= $self->lock_for_scope_fast;
	return 1 if $oidx->blob_exists($blob);
	if (my $xoids = PublicInbox::LeiSearch::xoids_for($self, $eml, 1)) {
		for my $docid (values %$xoids) {
			$oidx->add_xref3($docid, -1, $blob, '.');
		}
		$oidx->commit_lazy;
		if ($self->{-dedupe_oid}) {
			exists $xoids->{$blob} ? 1 : undef;
		} else {
			1;
		}
	} else {
		# n.b. above xoids_for fills out eml->{-lei_fake_mid} if needed
		unless ($smsg) {
			$smsg = bless {}, 'PublicInbox::Smsg';
			$smsg->{bytes} = 0;
			$smsg->populate($eml);
		}
		$smsg->{blob} //= $blob;
		$oidx->begin_lazy;
		$smsg->{num} = $oidx->adj_counter('eidx_docid', '+');
		$oidx->add_overview($eml, $smsg);
		$oidx->add_xref3($smsg->{num}, -1, $blob, '.');
		$oidx->commit_lazy;
		undef;
	}
}

sub prepare_dedupe {
	my ($self) = @_;
	$self->{oidx} //= do {
		my $creat = !-f $self->{-ovf};
		my $lk = $self->lock_for_scope; # git-config doesn't wait
		my $oidx = PublicInbox::OverIdx->new($self->{-ovf});
		$oidx->{-no_fsync} = 1;
		$oidx->dbh;
		if ($creat) {
			$oidx->{dbh}->do('PRAGMA journal_mode = WAL');
			$oidx->eidx_prep; # for xref3
		}
		$oidx
	};
}

sub over { $_[0]->{oidx} } # for xoids_for

# don't use ale->git directly since is_dup is called inside
# ale->git->cat_async callbacks
sub git { $_[0]->{git} //= PublicInbox::Git->new($_[0]->{ale}->git->{git_dir}) }

sub pause_dedupe {
	my ($self) = @_;
	git($self)->cleanup;
	my $lockfh = delete $self->{lockfh}; # from lock_for_scope_fast;
	my $oidx = delete($self->{oidx}) // return;
	$oidx->commit_lazy;
}

sub reset_dedupe {
	my ($self) = @_;
	prepare_dedupe($self);
	my $lk = $self->lock_for_scope_fast;
	for my $t (qw(xref3 over id2num)) {
		$self->{oidx}->{dbh}->do("DELETE FROM $t");
	}
	pause_dedupe($self);
}

sub mm { undef }

sub altid_map { {} }

sub cloneurl { [] }

# find existing directory containing a `lei.saved-search' file based on
# $dir_ref which is an output
sub output2lssdir {
	my ($self, $lei, $dir_ref, $fn_ref) = @_;
	my $dst = $$dir_ref; # imap://$MAILBOX, /path/to/maildir, /path/to/mbox
	my $dir = lss_dir_for($lei, \$dst, 1);
	my $f = "$dir/lei.saved-search";
	if (-f $f && -r _) {
		$self->{-cfg} = $lei->cfg_dump($f) // return;
		$$dir_ref = $dir;
		$$fn_ref = $f;
		return 1;
	}
	undef;
}

# cf. LeiDedupe->has_entries
sub has_entries {
	my $oidx = $_[0]->{oidx} // die 'BUG: no {oidx}';
	my @n = $oidx->{dbh}->selectrow_array('SELECT num FROM over LIMIT 1');
	scalar(@n) ? 1 : undef;
}

no warnings 'once';
*nntp_url = \&cloneurl;
*base_url = \&PublicInbox::Inbox::base_url;
*smsg_eml = \&PublicInbox::Inbox::smsg_eml;
*smsg_by_mid = \&PublicInbox::Inbox::smsg_by_mid;
*msg_by_mid = \&PublicInbox::Inbox::msg_by_mid;
*modified = \&PublicInbox::Inbox::modified;
*recent = \&PublicInbox::Inbox::recent;
*max_git_epoch = *nntp_usable = *msg_by_path = \&mm; # undef
*isrch = *search = \&mm; # TODO
*DESTROY = \&pause_dedupe;

1;
