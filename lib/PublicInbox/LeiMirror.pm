# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# "lei add-external --mirror" support (also "public-inbox-clone");
package PublicInbox::LeiMirror;
use strict;
use v5.10.1;
use parent qw(PublicInbox::IPC);
use PublicInbox::Config;
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);
use IO::Compress::Gzip qw(gzip $GzipError);
use PublicInbox::Spawn qw(popen_rd spawn);
use File::Temp ();
use Fcntl qw(SEEK_SET O_CREAT O_EXCL O_WRONLY);
use Carp qw(croak);

sub _wq_done_wait { # dwaitpid callback (via wq_eof)
	my ($arg, $pid) = @_;
	my ($mrr, $lei) = @$arg;
	my $f = "$mrr->{dst}/mirror.done";
	if ($?) {
		$lei->child_error($?);
	} elsif (!unlink($f)) {
		warn("unlink($f): $!\n") unless $!{ENOENT};
	} else {
		if ($lei->{cmd} ne 'public-inbox-clone') {
			$lei->lazy_cb('add-external', '_finish_'
					)->($lei, $mrr->{dst});
		}
		$lei->qerr("# mirrored $mrr->{src} => $mrr->{dst}");
	}
	$lei->dclose;
}

# for old installations without manifest.js.gz
sub try_scrape {
	my ($self) = @_;
	my $uri = URI->new($self->{src});
	my $lei = $self->{lei};
	my $curl = $self->{curl} //= PublicInbox::LeiCurl->new($lei) or return;
	my $cmd = $curl->for_uri($lei, $uri, '--compressed');
	my $opt = { 0 => $lei->{0}, 2 => $lei->{2} };
	my $fh = popen_rd($cmd, undef, $opt);
	my $html = do { local $/; <$fh> } // die "read(curl $uri): $!";
	close($fh) or return $lei->child_error($?, "@$cmd failed");

	# we grep with URL below, we don't want Subject/From headers
	# making us clone random URLs
	my @html = split(/<hr>/, $html);
	my @urls = ($html[-1] =~ m!\bgit clone --mirror ([a-z\+]+://\S+)!g);
	my $url = $uri->as_string;
	chop($url) eq '/' or die "BUG: $uri not canonicalized";

	# since this is for old instances w/o manifest.js.gz, try v1 first
	return clone_v1($self) if grep(m!\A\Q$url\E/*\z!, @urls);
	if (my @v2_urls = grep(m!\A\Q$url\E/[0-9]+\z!, @urls)) {
		my %v2_epochs = map {
			my ($n) = (m!/([0-9]+)\z!);
			$n => URI->new($_)
		} @v2_urls; # uniq
		return clone_v2($self, \%v2_epochs);
	}

	# filter out common URLs served by WWW (e.g /$MSGID/T/)
	if (@urls && $url =~ s!/+[^/]+\@[^/]+/.*\z!! &&
			grep(m!\A\Q$url\E/*\z!, @urls)) {
		die <<"";
E: confused by scraping <$uri>, did you mean <$url>?

	}
	@urls and die <<"";
E: confused by scraping <$uri>, got ambiguous results:
@urls

	die "E: scraping <$uri> revealed nothing\n";
}

sub clone_cmd {
	my ($lei, $opt) = @_;
	my @cmd = qw(git);
	$opt->{$_} = $lei->{$_} for (0..2);
	# we support "-c $key=$val" for arbitrary git config options
	# e.g.: git -c http.proxy=socks5h://127.0.0.1:9050
	push(@cmd, '-c', $_) for @{$lei->{opt}->{c} // []};
	push @cmd, qw(clone --mirror);
	push @cmd, '-q' if $lei->{opt}->{quiet};
	push @cmd, '-v' if $lei->{opt}->{verbose};
	# XXX any other options to support?
	# --reference is tricky with multiple epochs...
	@cmd;
}

sub ft_rename ($$$) {
	my ($ft, $dst, $open_mode) = @_;
	my $fn = $ft->filename;
	my @st = stat($dst);
	my $mode = @st ? ($st[2] & 07777) : ($open_mode & ~umask);
	chmod($mode, $ft) or croak "E: chmod $fn: $!";
	rename($fn, $dst) or croak "E: rename($fn => $ft): $!";
	$ft->unlink_on_destroy(0);
}

sub _get_txt { # non-fatal
	my ($self, $endpoint, $file, $mode) = @_;
	my $uri = URI->new($self->{src});
	my $lei = $self->{lei};
	my $path = $uri->path;
	chop($path) eq '/' or die "BUG: $uri not canonicalized";
	$uri->path("$path/$endpoint");
	my $ft = File::Temp->new(TEMPLATE => "$file-XXXX", DIR => $self->{dst});
	my $opt = { 0 => $lei->{0}, 1 => $lei->{1}, 2 => $lei->{2} };
	my $cmd = $self->{curl}->for_uri($lei, $uri,
					qw(--compressed -R -o), $ft->filename);
	my $cerr = run_reap($lei, $cmd, $opt);
	return "$uri missing" if ($cerr >> 8) == 22;
	return "# @$cmd failed (non-fatal)" if $cerr;
	ft_rename($ft, "$self->{dst}/$file", $mode);
	undef; # success
}

# tries the relatively new /$INBOX/_/text/config/raw endpoint
sub _try_config {
	my ($self) = @_;
	my $dst = $self->{dst};
	if (!-d $dst || !mkdir($dst)) {
		require File::Path;
		File::Path::mkpath($dst);
		-d $dst or die "mkpath($dst): $!\n";
	}
	my $err = _get_txt($self,
			qw(_/text/config/raw inbox.config.example), 0444);
	return warn($err, "\n") if $err;
	my $f = "$self->{dst}/inbox.config.example";
	my $cfg = PublicInbox::Config->git_config_dump($f, $self->{lei}->{2});
	my $ibx = $self->{ibx} = {};
	for my $sec (grep(/\Apublicinbox\./, @{$cfg->{-section_order}})) {
		for (qw(address newsgroup nntpmirror)) {
			$ibx->{$_} = $cfg->{"$sec.$_"};
		}
	}
}

sub set_description ($) {
	my ($self) = @_;
	my $f = "$self->{dst}/description";
	open my $fh, '+>>', $f or die "open($f): $!";
	seek($fh, 0, SEEK_SET) or die "seek($f): $!";
	chomp(my $d = do { local $/; <$fh> } // die "read($f): $!");
	if ($d eq '($INBOX_DIR/description missing)' ||
			$d =~ /^Unnamed repository/ || $d !~ /\S/) {
		seek($fh, 0, SEEK_SET) or die "seek($f): $!";
		truncate($fh, 0) or die "truncate($f): $!";
		print $fh "mirror of $self->{src}\n" or die "print($f): $!";
		close $fh or die "close($f): $!";
	}
}

sub index_cloned_inbox {
	my ($self, $iv) = @_;
	my $lei = $self->{lei};
	my $err = _get_txt($self, qw(description description), 0666);
	warn($err, "\n") if $err; # non fatal
	eval { set_description($self) };
	warn $@ if $@;

	# n.b. public-inbox-clone works w/o (SQLite || Xapian)
	# lei is useless without Xapian + SQLite
	if ($lei->{cmd} ne 'public-inbox-clone') {
		my $ibx = delete($self->{ibx}) // {
			address => [ 'lei@example.com' ],
			version => $iv,
		};
		$ibx->{inboxdir} = $self->{dst};
		PublicInbox::Inbox->new($ibx);
		PublicInbox::InboxWritable->new($ibx);
		my $opt = {};
		for my $sw ($lei->index_opt) {
			my ($k) = ($sw =~ /\A([\w-]+)/);
			$opt->{$k} = $lei->{opt}->{$k};
		}
		# force synchronous dwaitpid for v2:
		local $PublicInbox::DS::in_loop = 0;
		my $cfg = PublicInbox::Config->new(undef, $lei->{2});
		my $env = PublicInbox::Admin::index_prepare($opt, $cfg);
		local %ENV = (%ENV, %$env) if $env;
		PublicInbox::Admin::progress_prepare($opt, $lei->{2});
		PublicInbox::Admin::index_inbox($ibx, undef, $opt);
	}
	open my $x, '>', "$self->{dst}/mirror.done"; # for _wq_done_wait
}

sub run_reap {
	my ($lei, $cmd, $opt) = @_;
	$lei->qerr("# @$cmd");
	my $pid = spawn($cmd, undef, $opt);
	my $reap = PublicInbox::OnDestroy->new($lei->can('sigint_reap'), $pid);
	waitpid($pid, 0) == $pid or die "waitpid @$cmd: $!";
	@$reap = (); # cancel reap
	my $ret = $?;
	$? = 0; # don't let it influence normal exit
	$ret;
}

sub clone_v1 {
	my ($self) = @_;
	my $lei = $self->{lei};
	my $curl = $self->{curl} //= PublicInbox::LeiCurl->new($lei) or return;
	my $uri = URI->new($self->{src});
	defined($lei->{opt}->{epoch}) and
		die "$uri is a v1 inbox, --epoch is not supported\n";
	my $pfx = $curl->torsocks($lei, $uri) or return;
	my $cmd = [ @$pfx, clone_cmd($lei, my $opt = {}),
			$uri->as_string, $self->{dst} ];
	my $cerr = run_reap($lei, $cmd, $opt);
	return $lei->child_error($cerr, "@$cmd failed") if $cerr;
	_try_config($self);
	write_makefile($self->{dst}, 1);
	index_cloned_inbox($self, 1);
}

sub parse_epochs ($$) {
	my ($opt_epochs, $v2_epochs) = @_; # $epcohs "LOW..HIGH"
	$opt_epochs // return; # undef => all epochs
	my ($lo, $dotdot, $hi, @extra) = split(/(\.\.)/, $opt_epochs);
	undef($lo) if ($lo // '') eq '';
	my $re = qr/\A~?[0-9]+\z/;
	if (@extra || (($lo // '0') !~ $re) ||
			(($hi // '0') !~ $re) ||
			!(grep(defined, $lo, $hi))) {
		die <<EOM;
--epoch=$opt_epochs not in the form of `LOW..HIGH', `LOW..', nor `..HIGH'
EOM
	}
	my @n = sort { $a <=> $b } keys %$v2_epochs;
	for (grep(defined, $lo, $hi)) {
		if (/\A[0-9]+\z/) {
			$_ > $n[-1] and die
"`$_' exceeds maximum available epoch ($n[-1])\n";
			$_ < $n[0] and die
"`$_' is lower than minimum available epoch ($n[0])\n";
		} elsif (/\A~([0-9]+)/) {
			my $off = -$1 - 1;
			$n[$off] // die "`$_' is out of range\n";
			$_ = $n[$off];
		} else { die "`$_' not understood\n" }
	}
	defined($lo) && defined($hi) && $lo > $hi and die
"low value (`$lo') exceeds high (`$hi')\n";
	$lo //= $n[0] if $dotdot;
	$hi //= $n[-1] if $dotdot;
	$hi //= $lo;
	my $want = {};
	for ($lo..$hi) {
		if (defined $v2_epochs->{$_}) {
			$want->{$_} = 1;
		} else {
			warn
"# epoch $_ is not available (non-fatal, $lo..$hi)\n";
		}
	}
	$want
}

sub init_placeholder ($$) {
	my ($src, $edst) = @_;
	PublicInbox::Import::init_bare($edst);
	my $f = "$edst/config";
	open my $fh, '>>', $f or die "open($f): $!";
	print $fh <<EOM or die "print($f): $!";
[remote "origin"]
	url = $src
	fetch = +refs/*:refs/*
	mirror = true

; This git epoch was created read-only and "public-inbox-fetch"
; will not fetch updates for it unless write permission is added.
EOM
	close $fh or die "close:($f): $!";
}

sub clone_v2 ($$;$) {
	my ($self, $v2_epochs, $m) = @_; # $m => manifest.js.gz hashref
	my $lei = $self->{lei};
	my $curl = $self->{curl} //= PublicInbox::LeiCurl->new($lei) or return;
	my $pfx = $curl->torsocks($lei, (values %$v2_epochs)[0]) or return;
	my $dst = $self->{dst};
	my $want = parse_epochs($lei->{opt}->{epoch}, $v2_epochs);
	my (@src_edst, @read_only, @skip_nr);
	for my $nr (sort { $a <=> $b } keys %$v2_epochs) {
		my $uri = $v2_epochs->{$nr};
		my $src = $uri->as_string;
		my $edst = $dst;
		$src =~ m!/([0-9]+)(?:\.git)?\z! or die <<"";
failed to extract epoch number from $src

		$1 + 0 == $nr or die "BUG: <$uri> miskeyed $1 != $nr";
		$edst .= "/git/$nr.git";
		if (!$want || $want->{$nr}) {
			push @src_edst, $src, $edst;
		} else { # create a placeholder so users only need to chmod +w
			init_placeholder($src, $edst);
			push @read_only, $edst;
			push @skip_nr, $nr;
		}
	}
	if (@skip_nr) { # filter out the epochs we skipped
		my $re = join('|', @skip_nr);
		my @del = grep(m!/git/$re\.git\z!, keys %$m);
		delete @$m{@del};
		$self->{-culled_manifest} = 1;
	}
	my $lk = bless { lock_path => "$dst/inbox.lock" }, 'PublicInbox::Lock';
	_try_config($self);
	my $on_destroy = $lk->lock_for_scope($$);
	my @cmd = clone_cmd($lei, my $opt = {});
	while (my ($src, $edst) = splice(@src_edst, 0, 2)) {
		my $cmd = [ @$pfx, @cmd, $src, $edst ];
		my $cerr = run_reap($lei, $cmd, $opt);
		return $lei->child_error($cerr, "@$cmd failed") if $cerr;
	}
	require PublicInbox::MultiGit;
	my $mg = PublicInbox::MultiGit->new($dst, 'all.git', 'git');
	$mg->fill_alternates;
	for my $i ($mg->git_epochs) { $mg->epoch_cfg_set($i) }
	for my $edst (@read_only) {
		my @st = stat($edst) or die "stat($edst): $!";
		chmod($st[2] & 0555, $edst) or die "chmod(a-w, $edst): $!";
	}
	write_makefile($self->{dst}, 2);
	undef $on_destroy; # unlock
	index_cloned_inbox($self, 2);
}

# PSGI mount prefixes and manifest.js.gz prefixes don't always align...
sub deduce_epochs ($$) {
	my ($m, $path) = @_;
	my ($v1_ent, @v2_epochs);
	my $path_pfx = '';
	$path =~ s!/+\z!!;
	do {
		$v1_ent = $m->{$path};
		@v2_epochs = grep(m!\A\Q$path\E/git/[0-9]+\.git\z!, keys %$m);
	} while (!defined($v1_ent) && !@v2_epochs &&
		$path =~ s!\A(/[^/]+)/!/! and $path_pfx .= $1);
	($path_pfx, $v1_ent ? $path : undef, @v2_epochs);
}

sub decode_manifest ($$$) {
	my ($fh, $fn, $uri) = @_;
	my $js;
	my $gz = do { local $/; <$fh> } // die "slurp($fn): $!";
	gunzip(\$gz => \$js, MultiStream => 1) or
		die "gunzip($uri): $GunzipError\n";
	my $m = eval { PublicInbox::Config->json->decode($js) };
	die "$uri: error decoding `$js': $@\n" if $@;
	ref($m) eq 'HASH' or die "$uri unknown type: ".ref($m);
	$m;
}

sub try_manifest {
	my ($self) = @_;
	my $uri = URI->new($self->{src});
	my $lei = $self->{lei};
	my $curl = $self->{curl} //= PublicInbox::LeiCurl->new($lei) or return;
	my $path = $uri->path;
	chop($path) eq '/' or die "BUG: $uri not canonicalized";
	$uri->path($path . '/manifest.js.gz');
	my $pdir = $lei->rel2abs($self->{dst});
	$pdir =~ s!/[^/]+/?\z!!;
	my $ft = File::Temp->new(TEMPLATE => 'm-XXXX',
				UNLINK => 1, DIR => $pdir, SUFFIX => '.tmp');
	my $fn = $ft->filename;
	my ($bn) = ($fn =~ m!/([^/]+)\z!);
	my $cmd = $curl->for_uri($lei, $uri, '-R', '-o', $bn);
	my $opt = { -C => $pdir };
	$opt->{$_} = $lei->{$_} for (0..2);
	my $cerr = run_reap($lei, $cmd, $opt);
	if ($cerr) {
		return try_scrape($self) if ($cerr >> 8) == 22; # 404 missing
		return $lei->child_error($cerr, "@$cmd failed");
	}
	my $m = eval { decode_manifest($ft, $fn, $uri) };
	if ($@) {
		warn $@;
		return try_scrape($self);
	}
	my ($path_pfx, $v1_path, @v2_epochs) = deduce_epochs($m, $path);
	if (@v2_epochs) {
		# It may be possible to have v1 + v2 in parallel someday:
		warn(<<EOM) if defined $v1_path;
# `$v1_path' appears to be a v1 inbox while v2 epochs exist:
# @v2_epochs
# ignoring $v1_path (use --inbox-version=1 to force v1 instead)
EOM
		my %v2_epochs = map {
			$uri->path($path_pfx.$_);
			my ($n) = ("$uri" =~ m!/([0-9]+)\.git\z!);
			$n => $uri->clone
		} @v2_epochs;
		clone_v2($self, \%v2_epochs, $m);
	} elsif (defined $v1_path) {
		clone_v1($self);
	} else {
		die "E: confused by <$uri>, possible matches:\n\t",
			join(', ', sort keys %$m), "\n";
	}
	if (delete $self->{-culled_manifest}) { # set by clone_v2
		# write the smaller manifest if epochs were skipped so
		# users won't have to delete manifest if they +w an
		# epoch they no longer want to skip
		my $json = PublicInbox::Config->json->encode($m);
		gzip(\$json => $fn) or die "gzip: $GzipError";
	}
	ft_rename($ft, "$self->{dst}/manifest.js.gz", 0666);
}

sub start_clone_url {
	my ($self) = @_;
	return try_manifest($self) if $self->{src} =~ m!\Ahttps?://!;
	die "TODO: non-HTTP/HTTPS clone of $self->{src} not supported, yet";
}

sub do_mirror { # via wq_io_do
	my ($self) = @_;
	my $lei = $self->{lei};
	umask($lei->{client_umask}) if defined $lei->{client_umask};
	eval {
		my $iv = $lei->{opt}->{'inbox-version'};
		if (defined $iv) {
			return clone_v1($self) if $iv == 1;
			return try_scrape($self) if $iv == 2;
			die "bad --inbox-version=$iv\n";
		}
		return start_clone_url($self) if $self->{src} =~ m!://!;
		die "TODO: cloning local directories not supported, yet";
	};
	$lei->fail($@) if $@;
}

sub start {
	my ($cls, $lei, $src, $dst) = @_;
	my $self = bless { src => $src, dst => $dst }, $cls;
	if ($src =~ m!https?://!) {
		require URI;
		require PublicInbox::LeiCurl;
	}
	require PublicInbox::Lock;
	require PublicInbox::Inbox;
	require PublicInbox::Admin;
	require PublicInbox::InboxWritable;
	$lei->request_umask;
	my ($op_c, $ops) = $lei->workers_start($self, 1);
	$lei->{wq1} = $self;
	$self->wq_io_do('do_mirror', []);
	$self->wq_close(1);
	$lei->wait_wq_events($op_c, $ops);
}

sub ipc_atfork_child {
	my ($self) = @_;
	$self->{lei}->_lei_atfork_child;
	$SIG{TERM} = sub { exit(128 + 15) }; # trigger OnDestroy $reap
	$self->SUPER::ipc_atfork_child;
}

sub write_makefile {
	my ($dir, $ibx_ver) = @_;
	my $f = "$dir/Makefile";
	if (sysopen my $fh, $f, O_CREAT|O_EXCL|O_WRONLY) {
		print $fh <<EOM or die "print($f) $!";
# This is a v$ibx_ver public-inbox, see the public-inbox-v$ibx_ver-format(5)
# manpage for more information on the format.  This Makefile is
# intended as a familiar wrapper for users unfamiliar with
# public-inbox-* commands.
#
# See the respective manpages for public-inbox-fetch(1),
# public-inbox-index(1), etc for more information on
# some of the commands used by this Makefile.
#
# This Makefile will not be modified nor read by public-inbox,
# so you may edit it freely with your own convenience targets
# and notes.  public-inbox-fetch will recreate it if removed.
EOM
		print $fh <<'EOM' or die "print($f): $!";
# the default target:
help :
	@echo Common targets:
	@echo '    make fetch        - fetch from remote git repostorie(s)'
	@echo '    make update       - fetch and update index '
	@echo
	@echo Rarely needed targets:
	@echo '    make reindex      - may be needed for new features/bugfixes'
	@echo '    make compact      - rewrite Xapian storage to save space'

fetch :
	public-inbox-fetch
update :
	@if ! public-inbox-fetch --exit-code; \
	then \
		c=$$?; \
		test $$c -eq 127 && exit 0; \
		exit $$c; \
	elif test -f msgmap.sqlite3 || test -f public-inbox/msgmap.sqlite3; \
	then \
		public-inbox-index; \
	else \
		echo 'public-inbox index not initialized'; \
		echo 'see public-inbox-index(1) man page'; \
	fi
reindex :
	public-inbox-index --reindex
compact :
	public-inbox-compact

.PHONY : help fetch update reindex compact
EOM
		close $fh or die "close($f): $!";
	} else {
		die "open($f): $!" unless $!{EEXIST};
	}
}

1;
