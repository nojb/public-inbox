# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# "lei refresh-mail-sync" drops dangling sync information
# and attempts to detect moved files
package PublicInbox::LeiRefreshMailSync;
use strict;
use v5.10.1;
use parent qw(PublicInbox::IPC PublicInbox::LeiInput);
use PublicInbox::LeiImport;
use PublicInbox::InboxWritable qw(eml_from_path);
use PublicInbox::Import;

sub folder_missing { # may be called by LeiInput
	my ($self, $folder) = @_;
	$self->{lms}->forget_folders($folder);
}

sub prune_mdir { # lms->each_src callback
	my ($oidbin, $id, $self, $mdir) = @_;
	my @try = $$id =~ /:2,[a-zA-Z]*\z/ ? qw(cur new) : qw(new cur);
	for (@try) { return if -f "$mdir/$_/$$id" }
	# both tries failed
	$self->{lms}->clear_src("maildir:$mdir", $id);
}

sub prune_imap { # lms->each_src callback
	my ($oidbin, $uid, $self, $uids, $url) = @_;
	return if exists $uids->{$uid};
	$self->{lms}->clear_src($url, $uid);
}

# detects missed file moves
sub pmdir_cb { # called via LeiPmdir->each_mdir_fn
	my ($self, $f, $fl) = @_;
	my ($folder, $bn) = ($f =~ m!\A(.+?)/(?:new|cur)/([^/]+)\z!) or
		die "BUG: $f was not from a Maildir?";
	substr($folder, 0, 0) = 'maildir:'; # add prefix
	return if scalar($self->{lms}->name_oidbin($folder, $bn));
	my $eml = eml_from_path($f) // return;
	my $oidbin = $self->{lei}->git_oid($eml)->digest;
	$self->{lms}->set_src($oidbin, $folder, \$bn);
}

sub input_path_url { # overrides PublicInbox::LeiInput::input_path_url
	my ($self, $input, @args) = @_;
	if ($input =~ /\Amaildir:(.+)/i) {
		$self->{lms}->each_src($input, \&prune_mdir, $self, $1);
		$self->{lse} //= $self->{lei}->{sto}->search;
		# call pmdir_cb (via maildir_each_file -> each_mdir_fn)
		PublicInbox::LeiInput::input_path_url($self, $input);
	} elsif ($input =~ m!\Aimaps?://!i) {
		my $uri = PublicInbox::URIimap->new($input);
		if (my $mic = $self->{lei}->{net}->mic_for_folder($uri)) {
			my $uids = $mic->search('UID 1:*');
			$uids = +{ map { $_ => undef } @$uids };
			$self->{lms}->each_src($$uri, \&prune_imap, $self,
						$uids, $$uri)
		} else {
			$self->folder_missing($$uri);
		}
	} else { die "BUG: $input not supported" }
	$self->{lei}->sto_done_request;
}

sub lei_refresh_mail_sync {
	my ($lei, @folders) = @_;
	my $sto = $lei->_lei_store or return $lei->fail(<<EOM);
lei/store uninitialized, see lei-import(1)
EOM
	my $lms = $lei->lms or return $lei->fail(<<EOM);
lei mail_sync.sqlite3 uninitialized, see lei-import(1)
EOM
	if (defined(my $all = $lei->{opt}->{all})) {
		$lms->group2folders($lei, $all, \@folders) or return;
	} else {
		$lms->arg2folder($lei, \@folders); # may die
	}
	$lms->lms_pause; # must be done before fork
	$sto->write_prepare($lei);
	my $self = bless { missing_ok => 1, lms => $lms }, __PACKAGE__;
	$lei->{opt}->{'mail-sync'} = 1; # for prepare_inputs
	$self->prepare_inputs($lei, \@folders) or return;
	my $ops = {};
	$lei->{auth}->op_merge($ops, $self, $lei) if $lei->{auth};
	(my $op_c, $ops) = $lei->workers_start($self, 1, $ops);
	$lei->{wq1} = $self;
	$lei->{-err_type} = 'non-fatal';
	net_merge_all_done($self) unless $lei->{auth};
	$lei->wait_wq_events($op_c, $ops); # net_merge_all_done if !{auth}
}

sub ipc_atfork_child { # needed for PublicInbox::LeiPmdir
	my ($self) = @_;
	PublicInbox::LeiInput::input_only_atfork_child($self);
	$self->{lms}->lms_write_prepare;
	undef;
}

sub _complete_refresh_mail_sync {
	my ($lei, @argv) = @_;
	my $lms = $lei->lms or return ();
	my $match_cb = $lei->complete_url_prepare(\@argv);
	my @k = $lms->folders($argv[-1] // undef, 1);
	my @m = map { $match_cb->($_) } @k;
	@m ? @m : @k
}

no warnings 'once';
*net_merge_all_done = \&PublicInbox::LeiInput::input_only_net_merge_all_done;

1;
