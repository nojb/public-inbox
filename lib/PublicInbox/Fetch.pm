# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# Wrapper to "git fetch" remote public-inboxes
package PublicInbox::Fetch;
use strict;
use v5.10.1;
use parent qw(PublicInbox::IPC);
use URI ();
use PublicInbox::Spawn qw(popen_rd run_die spawn);
use PublicInbox::Admin;
use PublicInbox::LEI;
use PublicInbox::LeiCurl;
use PublicInbox::LeiMirror;
use File::Temp ();
use PublicInbox::Config;
use IO::Compress::Gzip qw(gzip $GzipError);

sub new { bless {}, __PACKAGE__ }

sub fetch_args ($$) {
	my ($lei, $opt) = @_;
	my @cmd; # (git --git-dir=...) to be added by caller
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
	my ($lei, $dir) = @_;
	my $rn = $lei->{opt}->{'try-remote'} // [ 'origin', '_grokmirror' ];
	for my $r (@$rn) {
		my $cmd = [ qw(git config), "remote.$r.url" ];
		my $fh = popen_rd($cmd, undef, { -C => $dir, 2 => $lei->{2} });
		my $url = <$fh>;
		close $fh or next;
		$url =~ s!/*\n!!s;
		return $url;
	}
	undef
}

sub do_manifest ($$$) {
	my ($lei, $dir, $ibx_uri) = @_;
	my $muri = URI->new("$ibx_uri/manifest.js.gz");
	my $ft = File::Temp->new(TEMPLATE => 'm-XXXX',
				UNLINK => 1, DIR => $dir, SUFFIX => '.tmp');
	my $fn = $ft->filename;
	my $mf = "$dir/manifest.js.gz";
	my $m0; # current manifest.js.gz contents
	if (open my $fh, '<', $mf) {
		$m0 = eval {
			PublicInbox::LeiMirror::decode_manifest($fh, $mf, $mf)
		};
		warn($@) if $@;
	}
	my ($bn) = ($fn =~ m!/([^/]+)\z!);
	my $curl_cmd = $lei->{curl}->for_uri($lei, $muri, qw(-R -o), $bn);
	my $opt = { -C => $dir };
	$opt->{$_} = $lei->{$_} for (0..2);
	my $cerr = PublicInbox::LeiMirror::run_reap($lei, $curl_cmd, $opt);
	if ($cerr) {
		return [ 404, $muri ] if ($cerr >> 8) == 22; # 404 Missing
		$lei->child_error($cerr, "@$curl_cmd failed");
		return;
	}
	my $m1 = eval {
		PublicInbox::LeiMirror::decode_manifest($ft, $fn, $muri);
	} or return [ 404, $muri ];
	my $mdiff = { %$m1 };

	# filter out unchanged entries.  We check modified, too, since
	# fingerprints are SHA-1, so there's a teeny chance they'll collide
	while (my ($k, $v0) = each %{$m0 // {}}) {
		my $cur = $m1->{$k} // next;
		my $f0 = $v0->{fingerprint} // next;
		my $f1 = $cur->{fingerprint} // next;
		my $t0 = $v0->{modified} // next;
		my $t1 = $cur->{modified} // next;
		delete($mdiff->{$k}) if $f0 eq $f1 && $t0 == $t1;
	}
	unless (keys %$mdiff) {
		$lei->child_error(127 << 8) if $lei->{opt}->{'exit-code'};
		return;
	}
	my (undef, $v1_path, @v2_epochs) =
		PublicInbox::LeiMirror::deduce_epochs($mdiff, $ibx_uri->path);
	[ 200, $muri, $v1_path, \@v2_epochs, $ft, $mf, $m1 ];
}

sub get_fingerprint2 {
	my ($git_dir) = @_;
	require Digest::SHA;
	my $rd = popen_rd([qw(git show-ref)], undef, { -C => $git_dir });
	Digest::SHA::sha256(do { local $/; <$rd> });
}

sub writable_dir ($) {
	my ($dir) = @_;
	return unless -d $dir && -w _;
	my @st = stat($dir);
	$st[2] & 0222; # any writable bits set? (in case of root)
}

sub do_fetch { # main entry point
	my ($cls, $lei, $cd) = @_;
	my $ibx_ver;
	$lei->{curl} //= PublicInbox::LeiCurl->new($lei) or return;
	my $dir = PublicInbox::Admin::resolve_inboxdir($cd, \$ibx_ver);
	my ($ibx_uri, @git_dir, @epochs, $mg, @new_epoch, $skip);
	if ($ibx_ver == 1) {
		my $url = remote_url($lei, $dir) //
			die "E: $dir missing remote.*.url\n";
		$ibx_uri = URI->new($url);
	} else { # v2:
		require PublicInbox::MultiGit;
		$mg = PublicInbox::MultiGit->new($dir, 'all.git', 'git');
		@epochs = $mg->git_epochs;
		my ($git_url, $epoch);
		for my $nr (@epochs) { # try newest epoch, first
			my $edir = "$dir/git/$nr.git";
			if (!writable_dir($edir)) {
				$skip->{$nr} = 1;
				next;
			}
			next if defined $git_url;
			if (defined(my $url = remote_url($lei, $edir))) {
				$git_url = $url;
				$epoch = $nr;
			} else {
				warn "W: $edir missing remote.*.url\n";
				my $pid = spawn([qw(git config -l)], undef,
					{ 1 => $lei->{2}, 2 => $lei->{2} });
				waitpid($pid, 0);
				$lei->child_error($?) if $?;
			}
		}
		@epochs = grep { !$skip->{$_} } @epochs if $skip;
		$skip //= {}; # makes code below easier
		$git_url or die "Unable to determine git URL\n";
		my $inbox_url = $git_url;
		$inbox_url =~ s!/git/$epoch(?:\.git)?/?\z!! or
			$inbox_url =~ s!/$epoch(?:\.git)?/?\z!! or die <<EOM;
Unable to infer inbox URL from <$git_url>
EOM
		$ibx_uri = URI->new($inbox_url);
	}
	PublicInbox::LeiMirror::write_makefile($dir, $ibx_ver);
	$lei->qerr("# inbox URL: $ibx_uri/");
	my $res = do_manifest($lei, $dir, $ibx_uri) or return;
	my ($code, $muri, $v1_path, $v2_epochs, $ft, $mf, $m1) = @$res;
	if ($code == 404) {
		# any pre-manifest.js.gz instances running? Just fetch all
		# existing ones and unconditionally try cloning the next
		$v2_epochs = [ map { "$dir/git/$_.git" } @epochs ];
		if (@epochs) {
			my $n = $epochs[-1] + 1;
			push @$v2_epochs, "$dir/git/$n.git" if !$skip->{$n};
		}
	} else {
		$code == 200 or die "BUG unexpected code $code\n";
	}
	my $mculled;
	if ($ibx_ver == 2) {
		defined($v1_path) and warn <<EOM;
E: got v1 `$v1_path' when expecting v2 epoch(s) in <$muri>, WTF?
EOM
		@git_dir = map { "$dir/git/$_.git" } sort { $a <=> $b } map {
				my ($nr) = (m!/([0-9]+)\.git\z!g);
				$skip->{$nr} ? () : $nr;
			} @$v2_epochs;
		if ($m1 && scalar keys %$skip) {
			my $re = join('|', keys %$skip);
			my @del = grep(m!/git/$re\.git\z!, keys %$m1);
			delete @$m1{@del};
			$mculled = 1;
		}
	} else {
		$git_dir[0] = $dir;
	}
	# n.b. this expects all epochs are from the same host
	my $torsocks = $lei->{curl}->torsocks($lei, $muri);
	my $fp2 = $lei->{opt}->{'exit-code'} ? [] : undef;
	my $xit = 127;
	for my $d (@git_dir) {
		my $cmd;
		my $opt = {}; # for spawn
		if (-d $d) {
			$fp2->[0] = get_fingerprint2($d) if $fp2;
			$cmd = [ @$torsocks, 'git', "--git-dir=$d",
				fetch_args($lei, $opt) ];
		} else {
			my $e_uri = $ibx_uri->clone;
			my ($epath) = ($d =~ m!(/git/[0-9]+\.git)\z!);
			defined($epath) or
				die "BUG: $d is not an epoch to clone\n";
			$e_uri->path($ibx_uri->path.$epath);
			$cmd = [ @$torsocks,
				PublicInbox::LeiMirror::clone_cmd($lei, $opt),
				$$e_uri, $d];
			push @new_epoch, substr($epath, 5, -4) + 0;
			$xit = 0;
		}
		my $cerr = PublicInbox::LeiMirror::run_reap($lei, $cmd, $opt);
		# do not bail on clone failure if we didn't have a manifest
		if ($cerr && ($code == 200 || -d $d)) {
			$lei->child_error($cerr, "@$cmd failed");
			return;
		}
		if ($fp2 && $xit) {
			$fp2->[1] = get_fingerprint2($d);
			$xit = 0 if $fp2->[0] ne $fp2->[1];
		}
	}
	for my $i (@new_epoch) { $mg->epoch_cfg_set($i) }
	if ($ft) {
		my $fn = $ft->filename;
		if ($mculled) {
			my $json = PublicInbox::Config->json->encode($m1);
			gzip(\$json => $fn) or die "gzip: $GzipError";
		}
		rename($fn, $mf) or die "E: rename($fn, $mf): $!\n";
		$ft->unlink_on_destroy(0);
	}
	$lei->child_error($xit << 8) if $fp2 && $xit;
}

1;
