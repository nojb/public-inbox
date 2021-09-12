# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# "lei add-external --mirror" support
package PublicInbox::LeiMirror;
use strict;
use v5.10.1;
use parent qw(PublicInbox::IPC);
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);
use PublicInbox::Spawn qw(popen_rd spawn);
use File::Temp ();
use Fcntl qw(SEEK_SET);

sub do_finish_mirror { # dwaitpid callback
	my ($arg, $pid) = @_;
	my ($mrr, $lei) = @$arg;
	my $f = "$mrr->{dst}/mirror.done";
	if ($?) {
		$lei->child_error($?);
	} elsif (!unlink($f)) {
		$lei->err("unlink($f): $!") unless $!{ENOENT};
	} else {
		if ($lei->{cmd} ne 'public-inbox-clone') {
			$lei->add_external_finish($mrr->{dst});
		}
		$lei->qerr("# mirrored $mrr->{src} => $mrr->{dst}");
	}
	$lei->dclose;
}

sub _lei_wq_eof { # EOF callback for main daemon
	my ($lei) = @_;
	my $mrr = delete $lei->{wq1} or return $lei->fail;
	$mrr->wq_wait_old(\&do_finish_mirror, $lei);
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
	my @urls = ($html =~ m!\bgit clone --mirror ([a-z\+]+://\S+)!g);
	my $url = $uri->as_string;
	chop($url) eq '/' or die "BUG: $uri not canonicalized";

	# since this is for old instances w/o manifest.js.gz, try v1 first
	return clone_v1($self) if grep(m!\A\Q$url\E/*\z!, @urls);
	if (my @v2_urls = grep(m!\A\Q$url\E/[0-9]+\z!, @urls)) {
		my %v2_uris = map { $_ => URI->new($_) } @v2_urls; # uniq
		return clone_v2($self, [ values %v2_uris ]);
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

sub _get_txt { # non-fatal
	my ($self, $endpoint, $file) = @_;
	my $uri = URI->new($self->{src});
	my $lei = $self->{lei};
	my $path = $uri->path;
	chop($path) eq '/' or die "BUG: $uri not canonicalized";
	$uri->path("$path/$endpoint");
	my $cmd = $self->{curl}->for_uri($lei, $uri, '--compressed');
	my $ce = "$self->{dst}/$file";
	my $ft = File::Temp->new(TEMPLATE => "$file-XXXX",
				UNLINK => 1, DIR => $self->{dst});
	my $opt = { 0 => $lei->{0}, 1 => $ft, 2 => $lei->{2} };
	my $cerr = run_reap($lei, $cmd, $opt);
	return "$uri missing" if ($cerr >> 8) == 22;
	return "# @$cmd failed (non-fatal)" if $cerr;
	my $f = $ft->filename;
	rename($f, $ce) or return "rename($f, $ce): $! (non-fatal)";
	$ft->unlink_on_destroy(0);
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
	my $err = _get_txt($self, qw(_/text/config/raw inbox.config.example));
	return $self->{lei}->err($err) if $err;
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
	my $err = _get_txt($self, qw(description description));
	$lei->err($err) if $err; # non fatal
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
	open my $x, '>', "$self->{dst}/mirror.done"; # for do_finish_mirror
}

sub run_reap {
	my ($lei, $cmd, $opt) = @_;
	$lei->qerr("# @$cmd");
	$opt->{pgid} = 0 if $lei->{sock};
	my $pid = spawn($cmd, undef, $opt);
	my $reap = PublicInbox::OnDestroy->new($lei->can('sigint_reap'), $pid);
	waitpid($pid, 0) == $pid or die "waitpid @$cmd: $!";
	@$reap = (); # cancel reap
	$?
}

sub clone_v1 {
	my ($self) = @_;
	my $lei = $self->{lei};
	my $curl = $self->{curl} //= PublicInbox::LeiCurl->new($lei) or return;
	my $uri = URI->new($self->{src});
	my $pfx = $curl->torsocks($lei, $uri) or return;
	my $cmd = [ @$pfx, clone_cmd($lei, my $opt = {}),
			$uri->as_string, $self->{dst} ];
	my $cerr = run_reap($lei, $cmd, $opt);
	return $lei->child_error($cerr, "@$cmd failed") if $cerr;
	_try_config($self);
	index_cloned_inbox($self, 1);
}

sub clone_v2 {
	my ($self, $v2_uris) = @_;
	my $lei = $self->{lei};
	my $curl = $self->{curl} //= PublicInbox::LeiCurl->new($lei) or return;
	my $pfx //= $curl->torsocks($lei, $v2_uris->[0]) or return;
	my @epochs;
	my $dst = $self->{dst};
	my @src_edst;
	for my $uri (@$v2_uris) {
		my $src = $uri->as_string;
		my $edst = $dst;
		$src =~ m!/([0-9]+)(?:\.git)?\z! or die <<"";
failed to extract epoch number from $src

		my $nr = $1 + 0;
		$edst .= "/git/$nr.git";
		push @src_edst, [ $src, $edst ];
	}
	my $lk = bless { lock_path => "$dst/inbox.lock" }, 'PublicInbox::Lock';
	_try_config($self);
	my $on_destroy = $lk->lock_for_scope($$);
	my @cmd = clone_cmd($lei, my $opt = {});
	while (my $pair = shift(@src_edst)) {
		my $cmd = [ @$pfx, @cmd, @$pair ];
		my $cerr = run_reap($lei, $cmd, $opt);
		return $lei->child_error($cerr, "@$cmd failed") if $cerr;
	}
	undef $on_destroy; # unlock
	index_cloned_inbox($self, 2);
}

# PSGI mount prefixes and manifest.js.gz prefixes don't always align...
sub deduce_epochs ($$) {
	my ($m, $path) = @_;
	my ($v1_bare, @v2_epochs);
	my $path_pfx = '';
	$path =~ s!/+\z!!;
	do {
		$v1_bare = $m->{$path};
		@v2_epochs = grep(m!\A\Q$path\E/git/[0-9]+\.git\z!, keys %$m);
	} while (!defined($v1_bare) && !@v2_epochs &&
		$path =~ s!\A(/[^/]+)/!/! and $path_pfx .= $1);
	($path_pfx, $v1_bare, @v2_epochs);
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
	my $ft = File::Temp->new(TEMPLATE => 'manifest-XXXX',
				UNLINK => 1, DIR => $pdir);
	my $fn = $ft->filename;
	my $cmd = $curl->for_uri($lei, $uri, '-R', '-o', $fn);
	my $opt = { 0 => $lei->{0}, 1 => $lei->{1}, 2 => $lei->{2} };
	my $cerr = run_reap($lei, $cmd, $opt);
	if ($cerr) {
		return try_scrape($self) if ($cerr >> 8) == 22; # 404 missing
		return $lei->child_error($cerr, "@$cmd failed");
	}
	my $m = decode_manifest($ft, $fn, $uri);
	my ($path_pfx, $v1_bare, @v2_epochs) = deduce_epochs($m, $path);
	if (@v2_epochs) {
		# It may be possible to have v1 + v2 in parallel someday:
		$lei->err(<<EOM) if defined $v1_bare;
# `$v1_bare' appears to be a v1 inbox while v2 epochs exist:
# @v2_epochs
# ignoring $v1_bare (use --inbox-version=1 to force v1 instead)
EOM
		@v2_epochs = map {
			$uri->path($path_pfx.$_);
			$uri->clone
		} @v2_epochs;
		clone_v2($self, \@v2_epochs);
		my $fin = "$self->{dst}/manifest.js.gz";
		rename($fn, $fin) or die "E: rename($fn, $fin): $!";
		$ft->unlink_on_destroy(0);
	} elsif (defined $v1_bare) {
		clone_v1($self);
	} else {
		die "E: confused by <$uri>, possible matches:\n\t",
			join(', ', sort keys %$m), "\n";
	}
}

sub start_clone_url {
	my ($self) = @_;
	return try_manifest($self) if $self->{src} =~ m!\Ahttps?://!;
	die "TODO: non-HTTP/HTTPS clone of $self->{src} not supported, yet";
}

sub do_mirror { # via wq_io_do
	my ($self) = @_;
	my $lei = $self->{lei};
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

1;
