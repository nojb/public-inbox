# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# front-end for the "lei export-kw" sub-command
package PublicInbox::LeiExportKw;
use strict;
use v5.10.1;
use parent qw(PublicInbox::IPC PublicInbox::LeiInput);
use Errno qw(EEXIST ENOENT);

sub export_kw_md { # LeiMailSync->each_src callback
	my ($oidbin, $id, $self, $mdir) = @_;
	my $oidhex = unpack('H*', $oidbin);
	my $sto_kw = $self->{lse}->oid_keywords($oidhex) or return;
	my $bn = $$id;
	my ($md_kw, $unknown, @try);
	if ($bn =~ s/:2,([a-zA-Z]*)\z//) {
		($md_kw, $unknown) = PublicInbox::MdirReader::flags2kw($1);
		@try = qw(cur new);
	} else {
		$unknown = [];
		@try = qw(new cur);
	}
	if ($self->{-merge_kw} && $md_kw) { # merging keywords is the default
		@$sto_kw{keys %$md_kw} = values(%$md_kw);
	}
	$bn .= ':2,'.
		PublicInbox::LeiToMail::kw2suffix([keys %$sto_kw], @$unknown);
	my $dst = "$mdir/cur/$bn";
	my @fail;
	my $lei = $self->{lei};
	for my $d (@try) {
		my $src = "$mdir/$d/$$id";
		next if $src eq $dst;

		# we use link(2) + unlink(2) since rename(2) may
		# inadvertently clobber if the "uniquefilename" part wasn't
		# actually unique.
		if (link($src, $dst)) { # success
			# unlink(2) may ENOENT from parallel invocation,
			# ignore it, but not other serious errors
			if (!unlink($src) and $! != ENOENT) {
				$lei->child_error(1, "E: unlink($src): $!");
			}
			$lei->{sto}->ipc_do('lms_mv_src', "maildir:$mdir",
						$oidbin, $id, $bn);
			return; # success anyways if link(2) worked
		}
		if ($! == ENOENT && !-e $src) { # some other process moved it
			$lei->{sto}->ipc_do('lms_clear_src',
						"maildir:$mdir", $id);
			next;
		}
		push @fail, $src if $! != EEXIST;
	}
	return unless @fail;
	# both tries failed
	my $e = $!;
	my $orig = '['.join('|', @fail).']';
	$lei->child_error(1, "link($orig, $dst) ($oidhex): $e");
}

sub export_kw_imap { # LeiMailSync->each_src callback
	my ($oidbin, $id, $self, $mic) = @_;
	my $oidhex = unpack('H*', $oidbin);
	my $sto_kw = $self->{lse}->oid_keywords($oidhex) or return;
	$self->{imap_mod_kw}->($self->{nwr}, $mic, $id, [ keys %$sto_kw ]);
}

# overrides PublicInbox::LeiInput::input_path_url
sub input_path_url {
	my ($self, $input, @args) = @_;
	my $lms = $self->{-lms_ro} //= $self->{lse}->lms;
	if ($input =~ /\Amaildir:(.+)/i) {
		my $mdir = $1;
		require PublicInbox::LeiToMail; # kw2suffix
		$lms->each_src($input, \&export_kw_md, $self, $mdir);
	} elsif ($input =~ m!\Aimaps?://!i) {
		my $uri = PublicInbox::URIimap->new($input);
		my $mic = $self->{nwr}->mic_for_folder($uri);
		$lms->each_src($$uri, \&export_kw_imap, $self, $mic);
		$mic->expunge;
	} else { die "BUG: $input not supported" }
	my $wait = $self->{lei}->{sto}->ipc_do('done');
}

sub lei_export_kw {
	my ($lei, @folders) = @_;
	my $sto = $lei->_lei_store or return $lei->fail(<<EOM);
lei/store uninitialized, see lei-import(1)
EOM
	my $lse = $sto->search;
	my $lms = $lse->lms or return $lei->fail(<<EOM);
lei mail_sync uninitialized, see lei-import(1)
EOM
	my $opt = $lei->{opt};
	if (defined(my $all = $opt->{all})) { # --all=<local|remote>
		$lms->group2folders($lei, $all, \@folders) or return;
	} else {
		my $err = $lms->arg2folder($lei, \@folders);
		$lei->qerr(@{$err->{qerr}}) if $err->{qerr};
		return $lei->fail($err->{fail}) if $err->{fail};
	}
	my $self = bless { lse => $lse }, __PACKAGE__;
	$lei->{opt}->{'mail-sync'} = 1; # for prepare_inputs
	$self->prepare_inputs($lei, \@folders) or return;
	my $j = $opt->{jobs} // scalar(@{$self->{inputs}}) || 1;
	if (my @ro = grep(!/\A(?:maildir|imaps?):/i, @folders)) {
		return $lei->fail("cannot export to read-only folders: @ro");
	}
	my $m = $opt->{mode} // 'merge';
	if ($m eq 'merge') { # default
		$self->{-merge_kw} = 1;
	} elsif ($m eq 'set') {
	} else {
		return $lei->fail(<<EOM);
--mode=$m not supported (`set' or `merge')
EOM
	}
	if (my $net = $lei->{net}) {
		require PublicInbox::NetWriter;
		$self->{nwr} = bless $net, 'PublicInbox::NetWriter';
		$self->{imap_mod_kw} = $net->can($self->{-merge_kw} ?
					'imap_add_kw' : 'imap_set_kw');
	}
	undef $lms; # for fork
	my $ops = {};
	$sto->write_prepare($lei);
	$lei->{auth}->op_merge($ops, $self) if $lei->{auth};
	$self->{-wq_nr_workers} = $j // 1; # locked
	(my $op_c, $ops) = $lei->workers_start($self, $j, $ops);
	$lei->{wq1} = $self;
	$lei->{-err_type} = 'non-fatal';
	net_merge_all_done($self) unless $lei->{auth};
	$lei->wait_wq_events($op_c, $ops); # net_merge_all_done if !{auth}
}

sub _complete_export_kw {
	my ($lei, @argv) = @_;
	my $sto = $lei->_lei_store or return;
	my $lms = $sto->search->lms or return;
	my $match_cb = $lei->complete_url_prepare(\@argv);
	map { $match_cb->($_) } $lms->folders;
}

no warnings 'once';

*ipc_atfork_child = \&PublicInbox::LeiInput::input_only_atfork_child;
*net_merge_all_done = \&PublicInbox::LeiInput::input_only_net_merge_all_done;

# the following works even when LeiAuth is lazy-loaded
*net_merge_all = \&PublicInbox::LeiAuth::net_merge_all;

1;
