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
				$self->{lei}->child_error(1,
							"E: unlink($src): $!");
			}
			$self->{lms}->mv_src("maildir:$mdir",
						$oidbin, $id, $bn) or die;
			return; # success anyways if link(2) worked
		}
		if ($! == ENOENT && !-e $src) { # some other process moved it
			$self->{lms}->clear_src("maildir:$mdir", $id);
			next;
		}
		push @fail, $src if $! != EEXIST;
	}
	return unless @fail;
	# both tries failed
	my $e = $!;
	my $orig = '['.join('|', @fail).']';
	$self->{lei}->child_error(1, "link($orig, $dst) ($oidhex): $e");
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
	my $lms = $self->{lms} //= $self->{lse}->lms;
	$lms->lms_begin;
	if ($input =~ /\Amaildir:(.+)/i) {
		my $mdir = $1;
		require PublicInbox::LeiToMail; # kw2suffix
		$lms->each_src($input, \&export_kw_md, $self, $mdir);
	} elsif ($input =~ m!\Aimaps?://i!) {
		my $uri = PublicInbox::URIimap->new($input);
		my $mic = $self->{nwr}->mic_for_folder($uri);
		$lms->each_src($$uri, \&export_kw_imap, $self, $mic);
		$mic->expunge;
	} else { die "BUG: $input not supported" }
	$lms->lms_commit;
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
	my $all = $opt->{all};
	my @all = $lms->folders;
	if (defined $all) { # --all=<local|remote>
		my %x = map { $_ => $_ } split(/,/, $all);
		my @ok = grep(defined, delete(@x{qw(local remote), ''}));
		my @no = keys %x;
		if (@no) {
			@no = (join(',', @no));
			return $lei->fail(<<EOM);
--all=@no not accepted (must be `local' and/or `remote')
EOM
		}
		my (%seen, @inc);
		for my $ok (@ok) {
			if ($ok eq 'local') {
				@inc = grep(!m!\A[a-z0-9\+]+://!i, @all);
			} elsif ($ok eq 'remote') {
				@inc = grep(m!\A[a-z0-9\+]+://!i, @all);
			} elsif ($ok ne '') {
				return $lei->fail("--all=$all not understood");
			} else {
				@inc = @all;
			}
			for (@inc) {
				push(@folders, $_) unless $seen{$_}++;
			}
		}
		return $lei->fail(<<EOM) if !@folders;
no --mail-sync folders known to lei
EOM
	} else {
		my %all = map { $_ => 1 } @all;
		my @no;
		for (@folders) {
			next if $all{$_}; # ok
			if (-d "$_/new" && -d "$_/cur") {
				my $d = 'maildir:'.$lei->rel2abs($_);
				push(@no, $_) unless $all{$d};
				$_ = $d;
			} elsif (m!\Aimaps?://!i) {
				my $orig = $_;
				my $res = $lms->match_imap_url($orig, $all);
				if (ref $res) {
					$_ = $$res;
					$lei->qerr(<<EOM);
# using `$res' instead of `$orig'
EOM
				} else {
					$lei->err($res) if defined $res;
					push @no, $orig;
				}
			} else {
				push @no, $_;
			}
		}
		my $no = join("\n\t", @no);
		return $lei->fail(<<EOF) if @no;
No sync information for: $no
Run `lei ls-mail-sync' to display valid choices
EOF
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
	undef $lms;
	my $ops = {};
	$lei->{auth}->op_merge($ops, $self) if $lei->{auth};
	$self->{-wq_nr_workers} = $j // 1; # locked
	(my $op_c, $ops) = $lei->workers_start($self, $j, $ops);
	$lei->{wq1} = $self;
	$lei->{-err_type} = 'non-fatal';
	net_merge_all_done($self) unless $lei->{auth};
	$op_c->op_wait_event($ops); # calls net_merge_all_done if $lei->{auth}
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
