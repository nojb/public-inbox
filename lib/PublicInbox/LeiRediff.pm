# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# The "lei rediff" sub-command, regenerates diffs with new options
package PublicInbox::LeiRediff;
use strict;
use v5.10.1;
use parent qw(PublicInbox::IPC PublicInbox::LeiInput);
use File::Temp 0.19 (); # 0.19 for ->newdir
use PublicInbox::Spawn qw(spawn which);
use PublicInbox::MsgIter qw(msg_part_text);
use PublicInbox::ViewDiff;
use PublicInbox::LeiBlob;
use PublicInbox::Git qw(git_quote git_unquote);
use PublicInbox::Import;
use PublicInbox::LEI;
use PublicInbox::SolverGit;

my $MODE = '(100644|120000|100755|160000)';

sub rediff_user_cb { # called by solver when done
	my ($res, $self) = @_;
	my $lei = $self->{lei};
	my $log_buf = delete $lei->{log_buf};
	$$log_buf =~ s/^/# /sgm;
	ref($res) eq 'ARRAY' or return $lei->child_error(0, $$log_buf);
	$lei->qerr($$log_buf);
	my ($git, $oid, $type, $size, $di) = @$res;
	my $oid_want = delete $self->{cur_oid_want};

	# don't try to support all the git-show(1) options for non-blob,
	# this is just a convenience:
	$type ne 'blob' and return $lei->err(<<EOF);
# $oid is a $type of $size bytes in:
# $git->{git_dir} (wanted: $oid_want)
EOF
	$self->{blob}->{$oid_want} = $oid;
	push @{$self->{gits}}, $git if $git->{-tmp};
}

# returns a full blob for oid_want
sub solve_1 ($$$) {
	my ($self, $oid_want, $hints) = @_;
	return if $oid_want =~ /\A0+\z/;
	$self->{cur_oid_want} = $oid_want;
	my $solver = bless {
		gits => $self->{gits},
		user_cb => \&rediff_user_cb,
		uarg => $self,
		inboxes => [ $self->{lxs}->locals, @{$self->{rmt}} ],
	}, 'PublicInbox::SolverGit';
	open my $log, '+>', \(my $log_buf = '') or die "PerlIO::scalar: $!";
	$self->{lei}->{log_buf} = \$log_buf;
	local $PublicInbox::DS::in_loop = 0; # waitpid synchronously
	$solver->solve($self->{lei}->{env}, $log, $oid_want, $hints);
	$self->{blob}->{$oid_want}; # full OID
}

sub _lei_diff_prepare ($$) {
	my ($lei, $cmd) = @_;
	my $opt = $lei->{opt};
	push @$cmd, '--'.($opt->{color} && !$opt->{'no-color'} ? '' : 'no-').
			'color';
	for my $o (@PublicInbox::LEI::diff_opt) {
		my $c = '';
		# remove single char short option
		$o =~ s/\|([a-z0-9])\b//i and $c = $1;
		if ($o =~ s/=[is]@\z//) {
			my $v = $opt->{$o} or next;
			push @$cmd, map { $c ? "-$c$_" : "--$o=$_" } @$v;
		} elsif ($o =~ s/=[is]\z//) {
			my $v = $opt->{$o} // next;
			push @$cmd, $c ? "-$c$v" : "--$o=$v";
		} elsif ($o =~ s/:[is]\z//) {
			my $v = $opt->{$o} // next;
			push @$cmd, $c ? "-$c$v" :
					($v eq '' ? "--$o" : "--$o=$v");
		} elsif ($o =~ s/!\z//) {
			my $v = $opt->{$o} // next;
			push @$cmd, $v ? "--$o" : "--no-$o";
		} elsif ($opt->{$o}) {
			push @$cmd, $c ? "-$c" : "--$o";
		}
	}
}

sub diff_ctxq ($$) {
	my ($self, $ctxq) = @_;
	return unless $ctxq;
	my $blob = $self->{blob};
	my $ta = <<'EOM';
reset refs/heads/A
commit refs/heads/A
author <a@s> 0 +0000
committer <c@s> 0 +0000
data 0
EOM
	my $tb = $ta;
	$tb =~ tr!A!B!;
	my $lei = $self->{lei};
	while (my ($oid_a, $oid_b, $pa, $pb, $ma, $mb) = splice(@$ctxq, 0, 6)) {
		my $xa = $blob->{$oid_a} //= solve_1($self, $oid_a,
							{ path_b => $pa });
		my $xb = $blob->{$oid_b} //= solve_1($self, $oid_b, {
						oid_a => $oid_a,
						path_a => $pa,
						path_b => $pb
					});
		$ta .= "M $ma $xa ".git_quote($pa)."\n" if $xa;
		$tb .= "M $mb $xb ".git_quote($pb)."\n" if $xb;
	}
	my $rw = $self->{gits}->[-1]; # has all known alternates
	if (!$rw->{-tmp}) {
		my $d = "$self->{rdtmp}/for_tree.git";
		-d $d or PublicInbox::Import::init_bare($d);
		my $f = "$d/objects/info/alternates"; # always overwrite
		open my $fh, '>', $f or die "open $f: $!";
		for my $git (@{$self->{gits}}) {
			print $fh $git->git_path('objects'),"\n";
		}
		close $fh or die "close $f: $!";
		$rw = PublicInbox::Git->new($d);
	}
	pipe(my ($r, $w)) or die "pipe: $!";
	my $pid = spawn(['git', "--git-dir=$rw->{git_dir}",
			qw(fast-import --quiet --done --date-format=raw)],
			$lei->{env}, { 2 => $lei->{2}, 0 => $r });
	close $r or die "close r fast-import: $!";
	print $w $ta, "\n", $tb, "\ndone\n" or die "print fast-import: $!";
	close $w or die "close w fast-import: $!";
	waitpid($pid, 0);
	die "fast-import failed: \$?=$?" if $?;

	my $cmd = [ 'diff' ];
	_lei_diff_prepare($lei, $cmd);
	$lei->qerr("# git @$cmd");
	push @$cmd, qw(A B);
	unshift @$cmd, 'git', "--git-dir=$rw->{git_dir}";
	$pid = spawn($cmd, $lei->{env}, { 2 => $lei->{2}, 1 => $lei->{1} });
	waitpid($pid, 0);
	$lei->child_error($?) if $?; # for git diff --exit-code
	undef;
}

sub wait_requote ($$$) { # OnDestroy callback
	my ($lei, $pid, $old_1) = @_;
	$lei->{1} = $old_1; # closes stdin of `perl -pE 's/^/> /'`
	waitpid($pid, 0) == $pid or die "BUG(?) waitpid: \$!=$! \$?=$?";
	$lei->child_error($?) if $?;
}

sub requote ($$) {
	my ($lei, $pfx) = @_;
	pipe(my($r, $w)) or die "pipe: $!";
	my $rdr = { 0 => $r, 1 => $lei->{1}, 2 => $lei->{2} };
	# $^X (perl) is overkill, but maybe there's a weird system w/o sed
	my $pid = spawn([$^X, '-pE', "s/^/$pfx/"], $lei->{env}, $rdr);
	my $old_1 = $lei->{1};
	$w->autoflush(1);
	binmode $w, ':utf8';
	$lei->{1} = $w;
	PublicInbox::OnDestroy->new(\&wait_requote, $lei, $pid, $old_1);
}

sub extract_oids { # Eml each_part callback
	my ($ary, $self) = @_;
	my ($p, undef, $idx) = @$ary;
	$self->{lei}->out($p->header_obj->as_string, "\n");
	my ($s, undef) = msg_part_text($p, $p->content_type || 'text/plain');
	defined $s or return;
	my $rq;
	if ($self->{dqre} && $s =~ s/$self->{dqre}//g) { # '> ' prefix(es)
		$rq = requote($self->{lei}, $1) if $self->{lei}->{opt}->{drq};
	}
	my @top = split($PublicInbox::ViewDiff::EXTRACT_DIFFS, $s);
	undef $s;
	my $blobs = $self->{blobs}; # blobs to resolve
	my $ctxq;
	while (defined(my $x = shift @top)) {
		if (scalar(@top) >= 4 &&
				$top[1] =~ $PublicInbox::ViewDiff::IS_OID &&
				$top[0] =~ $PublicInbox::ViewDiff::IS_OID) {
			my ($ma, $mb);
			$x =~ /^old mode $MODE/sm and $ma = $1;
			$x =~ /^new mode $MODE/sm and $mb = $1;
			if (!defined($ma) && $x =~
				/^index [a-z0-9]+\.\.[a-z0-9]+ $MODE/sm) {
				$ma = $mb = $1;
			}
			$ma //= '100644';
			$mb //= $ma;
			my ($oid_a, $oid_b, $pa, $pb) = splice(@top, 0, 4);
			$pa eq '/dev/null' or
				$pa = (split(m'/', git_unquote($pa), 2))[1];
			$pb eq '/dev/null' or
				$pb = (split(m'/', git_unquote($pb), 2))[1];
			$blobs->{$oid_a} //= undef;
			$blobs->{$oid_b} //= undef;
			push @$ctxq, $oid_a, $oid_b, $pa, $pb, $ma, $mb;
		} elsif ($ctxq) {
			my @out;
			for (split(/^/sm, $x)) {
				if (/\A-- \r?\n/s) { # email sig starts
					push @out, $_;
					$ctxq = diff_ctxq($self, $ctxq);
				} elsif ($ctxq && (/\A[\+\- ]/ || /\A@@ / ||
					# allow totally blank lines w/o leading
					# SP, git-apply does:
							/\A\r?\n/s)) {
					next;
				} else {
					push @out, $_;
				}
			}
			$self->{lei}->out(@out) if @out;
		} else {
			$ctxq = diff_ctxq($self, $ctxq);
			$self->{lei}->out($x);
		}
	}
	$ctxq = diff_ctxq($self, $ctxq);
}

# ensure dequoted parts are available for rebuilding patches:
sub dequote_add { # Eml each_part callback
	my ($ary, $self) = @_;
	my ($p, undef, $idx) = @$ary;
	my ($s, undef) = msg_part_text($p, $p->content_type || 'text/plain');
	defined $s or return;
	if ($s =~ s/$self->{dqre}//g) { # remove '> ' prefix(es)
		substr($s, 0, 0, "part-dequoted: $idx\n\n");
		utf8::encode($s);
		$self->{tmp_sto}->add_eml(PublicInbox::Eml->new(\$s));
	}
}

sub input_eml_cb { # callback for all emails
	my ($self, $eml) = @_;
	{
		local $SIG{__WARN__} = sub {
			return if "@_" =~ /^no email in From: .*? or Sender:/;
			return if PublicInbox::Eml::warn_ignore(@_);
			warn @_;
		};
		$self->{tmp_sto}->add_eml($eml);
		$eml->each_part(\&dequote_add, $self) if $self->{dqre};
		$self->{tmp_sto}->done;
	}
	$eml->each_part(\&extract_oids, $self, 1);
}

sub lei_rediff {
	my ($lei, @inputs) = @_;
	($lei->{opt}->{drq} && $lei->{opt}->{'dequote-only'}) and return
		$lei->fail('--drq and --dequote-only are mutually exclusive');
	($lei->{opt}->{drq} && !$lei->{opt}->{verbose}) and
		$lei->{opt}->{quiet} //= 1;
	$lei->_lei_store(1)->write_prepare($lei);
	$lei->{opt}->{'in-format'} //= 'eml';
	# maybe it's a non-email (code) blob from a coderepo
	my $git_dirs = $lei->{opt}->{'git-dir'} //= [];
	if ($lei->{opt}->{cwd} // 1) {
		my $cgd = PublicInbox::LeiBlob::get_git_dir($lei, '.');
		unshift(@$git_dirs, $cgd) if defined $cgd;
	}
	return $lei->fail('no --git-dir to try') unless @$git_dirs;
	my $lxs = $lei->lxs_prepare;
	if ($lxs->remotes) {
		require PublicInbox::LeiRemote;
		$lei->{curl} //= which('curl') or return
			$lei->fail('curl needed for', $lxs->remotes);
	}
	$lei->ale->refresh_externals($lxs, $lei);
	my $self = bless {
		-force_eml => 1, # for LeiInput->input_fh
		lxs => $lxs,
	}, __PACKAGE__;
	$self->prepare_inputs($lei, \@inputs) or return;
	my $isatty = -t $lei->{1};
	$lei->{opt}->{color} //= $isatty;
	$lei->start_pager if $isatty;
	my ($op_c, $ops) = $lei->workers_start($self, 1);
	$lei->{wq1} = $self;
	net_merge_all_done($self) unless $lei->{auth};
	$lei->wait_wq_events($op_c, $ops);
}

sub ipc_atfork_child {
	my ($self) = @_;
	PublicInbox::LeiInput::input_only_atfork_child(@_);
	my $lei = $self->{lei};
	$lei->{1}->autoflush(1);
	binmode $lei->{1}, ':utf8';
	$self->{blobs} = {}; # oidhex => filename
	$self->{rdtmp} = File::Temp->newdir('lei-rediff-XXXX', TMPDIR => 1);
	$self->{tmp_sto} = PublicInbox::LeiStore->new(
			"$self->{rdtmp}/tmp.store",
			{ creat => { nproc => 1 }, indexlevel => 'medium' });
	$self->{tmp_sto}->{priv_eidx}->{parallel} = 0;
	$self->{rmt} = [ $self->{tmp_sto}->search, map {
			PublicInbox::LeiRemote->new($lei, $_)
		} $self->{lxs}->remotes ];
	$self->{gits} = [ map {
			PublicInbox::Git->new($lei->rel2abs($_))
		} @{$self->{lei}->{opt}->{'git-dir'}} ];
	$lei->{env}->{'psgi.errors'} = $lei->{2}; # ugh...
	$lei->{env}->{TMPDIR} = $self->{rdtmp}->dirname;
	if (my $nr = ($lei->{opt}->{drq} || $lei->{opt}->{'dequote-only'})) {
		my $re = '\s*> ' x $nr;
		$self->{dqre} = qr/^($re)/ms;
	}
	undef;
}

no warnings 'once';
*net_merge_all_done = \&PublicInbox::LeiInput::input_only_net_merge_all_done;
1;
