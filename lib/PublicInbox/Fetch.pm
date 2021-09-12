# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# Wrapper to "git fetch" remote public-inboxes
package PublicInbox::Fetch;
use strict;
use v5.10.1;
use parent qw(PublicInbox::IPC);
use URI ();
use PublicInbox::Spawn qw(popen_rd);
use PublicInbox::Admin;
use PublicInbox::LEI;
use PublicInbox::LeiCurl;
use PublicInbox::LeiMirror;
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);
use File::Temp ();

sub new { bless {}, __PACKAGE__ }

sub fetch_cmd ($$) {
	my ($lei, $opt) = @_;
	my @cmd = qw(git);
	$opt->{$_} = $lei->{$_} for (0..2);
	# we support "-c $key=$val" for arbitrary git config options
	# e.g.: git -c http.proxy=socks5h://127.0.0.1:9050
	push(@cmd, '-c', $_) for @{$lei->{opt}->{c} // []};
	push @cmd, 'fetch';
	push @cmd, '-q' if $lei->{opt}->{quiet};
	push @cmd, '-v' if $lei->{opt}->{verbose};
	@cmd;
}

sub remote_url ($$) {
	my ($lei, $dir) = @_; # TODO: support non-"origin"?
	my $cmd = [ qw(git config remote.origin.url) ];
	my $fh = popen_rd($cmd, undef, { -C => $dir, 2 => $lei->{2} });
	my $url = <$fh>;
	close $fh or return;
	$url =~ s!/*\n!!s;
	$url;
}

sub do_manifest ($$$) {
	my ($lei, $dir, $ibx_uri) = @_;
	my $muri = URI->new("$ibx_uri/manifest.js.gz");
	my $ft = File::Temp->new(TEMPLATE => 'manifest-XXXX',
				UNLINK => 1, DIR => $dir);
	my $fn = $ft->filename;
	my @opt = (qw(-R -o), $fn);
	my $mf = "$dir/manifest.js.gz";
	my $m0; # current manifest.js.gz contents
	if (open my $fh, '<', $mf) {
		$m0 = eval {
			PublicInbox::LeiMirror::decode_manifest($fh, $mf, $mf)
		};
		$lei->err($@) if $@;
		push @opt, '-z', $mf if defined($m0);
	}
	my $curl_cmd = $lei->{curl}->for_uri($lei, $muri, @opt);
	my $opt = {};
	$opt->{$_} = $lei->{$_} for (0..2);
	my $cerr = PublicInbox::LeiMirror::run_reap($lei, $curl_cmd, $opt);
	if ($cerr) {
		return [ 404 ] if ($cerr >> 8) == 22; # 404 Missing
		$lei->child_error($cerr, "@$curl_cmd failed");
		return;
	}
	return [ 304 ] if !-s $ft; # 304 Not Modified via curl -z
	my $m1 = PublicInbox::LeiMirror::decode_manifest($ft, $fn, $muri);
	my $mdiff = { %$m1 };

	# filter out unchanged entries
	while (my ($k, $v0) = each %{$m0 // {}}) {
		my $cur = $m1->{$k} // next;
		my $f0 = $v0->{fingerprint} // next;
		my $f1 = $cur->{fingerprint} // next;
		my $t0 = $v0->{modified} // next;
		my $t1 = $cur->{modified} // next;
		delete($mdiff->{$k}) if $f0 eq $f1 && $t0 == $t1;
	}
	my (undef, $v1_path, @v2_epochs) =
		PublicInbox::LeiMirror::deduce_epochs($mdiff, $ibx_uri->path);
	[ 200, $v1_path, \@v2_epochs, $muri, $ft, $mf ];
}

sub do_fetch {
	my ($cls, $lei, $cd) = @_;
	my $ibx_ver;
	$lei->{curl} //= PublicInbox::LeiCurl->new($lei) or return;
	my $dir = PublicInbox::Admin::resolve_inboxdir($cd, \$ibx_ver);
	my ($ibx_uri, @git_dir, @epochs);
	if ($ibx_ver == 1) {
		my $url = remote_url($lei, $dir) //
			die "E: $dir missing remote.origin.url\n";
		$ibx_uri = URI->new($url);
	} else { # v2:
		opendir my $dh, "$dir/git" or die "opendir $dir/git: $!";
		@epochs = sort { $b <=> $a } map { substr($_, 0, -4) + 0 }
					grep(/\A[0-9]+\.git\z/, readdir($dh));
		my ($git_url, $epoch);
		for my $nr (@epochs) { # try newest epoch, first
			my $edir = "$dir/git/$nr.git";
			if (defined(my $url = remote_url($lei, $edir))) {
				$git_url = $url;
				$epoch = $nr;
				last;
			} else {
				warn "W: $edir missing remote.origin.url\n";
			}
		}
		$git_url or die "Unable to determine git URL\n";
		my $inbox_url = $git_url;
		$inbox_url =~ s!/git/$epoch(?:\.git)?/?\z!! or
			$inbox_url =~ s!/$epoch(?:\.git)?/?\z!! or die <<EOM;
Unable to infer inbox URL from <$git_url>
EOM
		$ibx_uri = URI->new($inbox_url);
	}
	$lei->qerr("# inbox URL: $ibx_uri/");
	my $res = do_manifest($lei, $dir, $ibx_uri) or return;
	my ($code, $v1_path, $v2_epochs, $muri, $ft, $mf) = @$res;
	return if $code == 304;
	if ($code == 404) {
		# any pre-manifest.js.gz instances running? Just fetch all
		# existing ones and unconditionally try cloning the next
		$v2_epochs = [ map {;
				"$dir/git/$_.git";
				} @epochs ];
		push @$v2_epochs, "$dir/git/".($epochs[-1] + 1) if @epochs;
	} else {
		$code == 200 or die "BUG unexpected code $code\n";
	}
	if ($ibx_ver == 2) {
		defined($v1_path) and warn <<EOM;
E: got v1 `$v1_path' when expecting v2 epoch(s) in <$muri>, WTF?
EOM
		@git_dir = map { "$dir/git/$_.git" } sort { $a <=> $b }
			map { my ($nr) = (m!/([0-9]+)\.git\z!g) } @$v2_epochs;
	} else {
		$git_dir[0] = $dir;
	}
	# n.b. this expects all epochs are from the same host
	my $torsocks = $lei->{curl}->torsocks($lei, $muri);
	for my $d (@git_dir) {
		my $cmd;
		my $opt = {}; # for spawn
		if (-d $d) {
			$opt->{-C} = $d;
			$cmd = [ @$torsocks, fetch_cmd($lei, $opt) ];
		} else {
			my $e_uri = $ibx_uri->clone;
			my ($epath) = ($d =~ m!/(git/[0-9]+\.git)\z!);
			defined($epath) or
				die "BUG: $d is not an epoch to clone\n";
			$e_uri->path($ibx_uri->path.$epath);
			$cmd = [ @$torsocks,
				PublicInbox::LeiMirror::clone_cmd($lei, $opt),
				$$e_uri, $d];
		}
		my $cerr = PublicInbox::LeiMirror::run_reap($lei, $cmd, $opt);
		# do not bail on clone failure if we didn't have a manifest
		if ($cerr && ($code == 200 || -d $d)) {
			$lei->child_error($cerr, "@$cmd failed");
			return;
		}
	}
	if ($ft) {
		my $fn = $ft->filename;
		rename($fn, $mf) or die "E: rename($fn, $mf): $!\n";
		$ft->unlink_on_destroy(0);
	}
}

1;
