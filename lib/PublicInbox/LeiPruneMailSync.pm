# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# "lei prune-mail-sync" drops dangling sync information
package PublicInbox::LeiPruneMailSync;
use strict;
use v5.10.1;
use parent qw(PublicInbox::IPC PublicInbox::LeiInput);
use PublicInbox::LeiExportKw;
use PublicInbox::InboxWritable qw(eml_from_path);

sub eml_match ($$) {
	my ($eml, $oidbin) = @_;
	$oidbin eq git_sha(length($oidbin) == 20 ? 1 : 256, $eml)->digest;
}

sub prune_mdir { # lms->each_src callback
	my ($oidbin, $id, $self, $mdir) = @_;
	my @try = $$id =~ /:2,[a-zA-Z]*\z/ ? qw(cur new) : qw(new cur);
	for my $d (@try) {
		my $src = "$mdir/$d/$$id";
		if ($self->{verify}) {
			my $eml = eml_from_path($src) or next;
			return if eml_match($eml, $oidbin);
		} elsif (-f $src) {
			return;
		}
	}
	# both tries failed
	$self->{lei}->qerr("# maildir:$mdir $$id gone");
	$self->{lei}->{sto}->ipc_do('lms_clear_src', "maildir:$mdir", $id);
}

sub prune_imap { # lms->each_src callback
	my ($oidbin, $uid, $self, $uids, $url) = @_;
	return if exists $uids->{$uid};
	$self->{lei}->qerr("# $url $uid gone");
	$self->{lei}->{sto}->ipc_do('lms_clear_src', $url, $uid);
}

sub input_path_url { # overrides PublicInbox::LeiInput::input_path_url
	my ($self, $input, @args) = @_;
	my $lms = $self->{-lms_ro} //= $self->{lei}->lms;
	if ($input =~ /\Amaildir:(.+)/i) {
		my $mdir = $1;
		$lms->each_src($input, \&prune_mdir, $self, $mdir);
	} elsif ($input =~ m!\Aimaps?://!i) {
		my $uri = PublicInbox::URIimap->new($input);
		my $mic = $self->{lei}->{net}->mic_for_folder($uri);
		my $uids = $mic->search('UID 1:*');
		$uids = +{ map { $_ => undef } @$uids };
		$lms->each_src($$uri, \&prune_imap, $self, $uids, $$uri);
	} else { die "BUG: $input not supported" }
	my $wait = $self->{lei}->{sto}->ipc_do('done');
}

sub lei_prune_mail_sync {
	my ($lei, @folders) = @_;
	my $sto = $lei->_lei_store or return $lei->fail(<<EOM);
lei/store uninitialized, see lei-import(1)
EOM
	if (my $lms = $lei->lms) {
		if (defined(my $all = $lei->{opt}->{all})) {
			$lms->group2folders($lei, $all, \@folders) or return;
		} else {
			my $err = $lms->arg2folder($lei, \@folders);
			$lei->qerr(@{$err->{qerr}}) if $err->{qerr};
			return $lei->fail($err->{fail}) if $err->{fail};
		}
	} else {
		return $lei->fail(<<EOM);
lei mail_sync.sqlite3 uninitialized, see lei-import(1)
EOM
	}
	$sto->write_prepare($lei);
	my $self = bless {}, __PACKAGE__;
	$lei->{opt}->{'mail-sync'} = 1; # for prepare_inputs
	$self->prepare_inputs($lei, \@folders) or return;
	my $j = $lei->{opt}->{jobs} || scalar(@{$self->{inputs}}) || 1;
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

no warnings 'once';
*_complete_prune_mail_sync = \&PublicInbox::LeiExportKw::_complete_export_kw;
*ipc_atfork_child = \&PublicInbox::LeiInput::input_only_atfork_child;
*net_merge_all_done = \&PublicInbox::LeiInput::input_only_net_merge_all_done;

1;
