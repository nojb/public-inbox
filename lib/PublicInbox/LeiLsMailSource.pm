# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# command for listing NNTP groups and IMAP folders,
# handy for users with git-credential-helper configured
# TODO: list JMAP labels
package PublicInbox::LeiLsMailSource;
use strict;
use v5.10.1;
use parent qw(PublicInbox::IPC PublicInbox::LeiInput);

sub input_path_url { # overrides LeiInput version
	my ($self, $url) = @_;
	# TODO: support ndjson and other JSONs we support elsewhere
	my $lei = $self->{lei};
	my $json = $lei->{json};
	my $ORS = $self->{lei}->{opt}->{z} ? "\0" : "\n";
	my @f;
	if ($url =~ m!\Aimaps?://!i) {
		my $uri = PublicInbox::URIimap->new($url);
		my $sec = $lei->{net}->can('uri_section')->($uri);
		my $mic = $lei->{net}->mic_get($uri);
		my $l = $mic->folders_hash($uri->path); # server-side filter
		@$l = map { $_->[2] } # undo Schwartzian transform below:
			sort { $a->[0] cmp $b->[0] || $a->[1] <=> $b->[1] }
			map { # prepare to sort -imapd slices numerically
				$_->{name} =~ /\A(.+?)\.([0-9]+)\z/ ?
				[ $1, $2 + 0, $_ ] : [ $_->{name}, -1, $_ ];
			} @$l;
		@f = map { "$sec/$_->{name}" } @$l;
		if ($json) {
			$_->{url} = "$sec/$_->{name}" for @$l;
			$lei->puts($json->encode($l));
		} else {
			if ($self->{lei}->{opt}->{url}) {
				$_->{name} = "$sec/$_->{name}" for @$l;
			}
			$lei->out(join($ORS, (map { $_->{name} } @$l), ''));
		}
	} elsif ($url =~ m!\A(?:nntps?|s?news)://!i) {
		my $uri = PublicInbox::URInntps->new($url);
		my $nn = $lei->{net}->nn_get($uri);
		my $l = $nn->newsgroups($uri->group); # name => description
		my $sec = $lei->{net}->can('uri_section')->($uri);
		if ($json) {
			my $all = $nn->list;
			my @x;
			for my $ng (sort keys %$l) {
				my $desc = $l->{$ng};

# we need to drop CR ourselves iff using IO::Socket::SSL since
# Net::Cmd::getline doesn't get used by Net::NNTP if TLS is in play, noted in:
# <https://rt.cpan.org/Ticket/Display.html?id=129966>
				$desc =~ s/\r\z//;

				my ($high, $low, $status) = @{$all->{$ng}};
				push @x, { name => $ng, url => "$sec/$ng",
					low => $low + 0,
					high => $high + 0, status => $status,
					description => $desc };
			}
			@f = map { "$sec/$_" } keys %$all;
			$lei->puts($json->encode(\@x));
		} else {
			@f = map { "$sec/$_" } keys %$l;
			if ($self->{lei}->{opt}->{url}) {
				$lei->out(join($ORS, sort(@f), ''));
			} else {
				$lei->out(join($ORS, sort(keys %$l), ''));
			}
		}
	} else { die "BUG: $url not supported" }
	if (@f) {
		my $fc = $lei->url_folder_cache;
		my $lk = $fc->lock_for_scope;
		$fc->dbh->begin_work;
		my $now = time;
		$fc->set($_, $now) for @f;
		$fc->dbh->commit;
	}
}

sub lei_ls_mail_source {
	my ($lei, $url, $pfx) = @_;
	$url =~ m!\A(?:imaps?|nntps?|s?news)://!i or return
		$lei->fail('only NNTP and IMAP URLs supported');
	my $self = bless { pfx => $pfx, -ls_ok => 1 }, __PACKAGE__;
	$self->{cfg} = $lei->_lei_cfg; # may be undef
	$self->prepare_inputs($lei, [ $url ]) or return;
	my $isatty = -t $lei->{1};
	if ($lei->{opt}->{l}) {
		my $json = ref(PublicInbox::Config->json)->new->utf8->canonical;
		$lei->{json} = $json;
		$json->ascii(1) if $lei->{opt}->{ascii};
		$json->pretty(1)->indent(2) if $isatty || $lei->{opt}->{pretty};
	}
	$lei->start_pager if $isatty;
	$lei->{-err_type} = 'non-fatal';
	$lei->wq1_start($self);
}

sub _complete_ls_mail_source {
	my ($lei, @argv) = @_;
	my $match_cb = $lei->complete_url_prepare(\@argv);
	my @k = $lei->url_folder_cache->keys($argv[-1] // undef, 1);
	my @m = map { $match_cb->($_) } @k;
	my %f = map { $_ => 1 } (@m ? @m : @k);
	if (my $lms = $lei->lms) {
		@k = $lms->folders($argv[-1] // undef, 1);
		@m = map { $match_cb->($_) } grep(m!\A[a-z]+://!, @k);
		if (@m) { @f{@m} = @m } else { @f{@k} = @k }
	}
	keys %f;
}

no warnings 'once';
*ipc_atfork_child = \&PublicInbox::LeiInput::input_only_atfork_child;
*net_merge_all_done = \&PublicInbox::LeiInput::input_only_net_merge_all_done;

1;
