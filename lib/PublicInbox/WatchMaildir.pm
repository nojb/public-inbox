# Copyright (C) 2016-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# ref: https://cr.yp.to/proto/maildir.html
#	http://wiki2.dovecot.org/MailboxFormat/Maildir
package PublicInbox::WatchMaildir;
use strict;
use warnings;
use PublicInbox::MIME;
use PublicInbox::Spawn qw(spawn);
use PublicInbox::InboxWritable;
use File::Temp qw//;
use PublicInbox::Filter::Base;
use PublicInbox::Spamcheck;
*REJECT = *PublicInbox::Filter::Base::REJECT;

sub new {
	my ($class, $config) = @_;
	my (%mdmap, @mdir, $spamc);
	my %uniq;

	# "publicinboxwatch" is the documented namespace
	# "publicinboxlearn" is legacy but may be supported
	# indefinitely...
	foreach my $pfx (qw(publicinboxwatch publicinboxlearn)) {
		my $k = "$pfx.watchspam";
		defined(my $dirs = $config->{$k}) or next;
		$dirs = [ $dirs ] if !ref($dirs);
		for my $dir (@$dirs) {
			if (is_maildir($dir)) {
				# skip "new", no MUA has seen it, yet.
				my $cur = "$dir/cur";
				my $old = $mdmap{$cur};
				if (ref($old)) {
					foreach my $ibx (@$old) {
						warn <<"";
"$cur already watched for `$ibx->{name}'

					}
					die;
				}
				push @mdir, $cur;
				$uniq{$cur}++;
				$mdmap{$cur} = 'watchspam';
			} else {
				warn "unsupported $k=$dir\n";
			}
		}
	}

	my $k = 'publicinboxwatch.spamcheck';
	my $default = undef;
	my $spamcheck = PublicInbox::Spamcheck::get($config, $k, $default);
	$spamcheck = _spamcheck_cb($spamcheck) if $spamcheck;

	$config->each_inbox(sub {
		# need to make all inboxes writable for spam removal:
		my $ibx = $_[0] = PublicInbox::InboxWritable->new($_[0]);

		my $watch = $ibx->{watch} or return;
		if (is_maildir($watch)) {
			my $watch_hdrs = [];
			if (my $wh = $ibx->{watchheader}) {
				my ($k, $v) = split(/:/, $wh, 2);
				push @$watch_hdrs, [ $k, qr/\Q$v\E/ ];
			}
			if (my $list_ids = $ibx->{listid}) {
				for (@$list_ids) {
					my $re = qr/<[ \t]*\Q$_\E[ \t]*>/;
					push @$watch_hdrs, ['List-Id', $re ];
				}
			}
			if (scalar @$watch_hdrs) {
				$ibx->{-watchheaders} = $watch_hdrs;
			}
			my $new = "$watch/new";
			my $cur = "$watch/cur";
			push @mdir, $new unless $uniq{$new}++;
			push @mdir, $cur unless $uniq{$cur}++;

			push @{$mdmap{$new} ||= []}, $ibx;
			push @{$mdmap{$cur} ||= []}, $ibx;
		} else {
			warn "watch unsupported: $k=$watch\n";
		}
	});
	return unless @mdir;

	my $mdre = join('|', map { quotemeta($_) } @mdir);
	$mdre = qr!\A($mdre)/!;
	bless {
		spamcheck => $spamcheck,
		mdmap => \%mdmap,
		mdir => \@mdir,
		mdre => $mdre,
		config => $config,
		importers => {},
		opendirs => {}, # dirname => dirhandle (in progress scans)
	}, $class;
}

sub _done_for_now {
	my ($self) = @_;
	my $importers = $self->{importers};
	foreach my $im (values %$importers) {
		$im->done;
	}
}

sub _try_fsn_paths {
	my ($self, $scan_re, $paths) = @_;
	foreach (@$paths) {
		my $path = $_->{path};
		if ($path =~ $scan_re) {
			scan($self, $path);
		} else {
			_try_path($self, $path);
		}
	}
	_done_for_now($self);
}

sub _remove_spam {
	my ($self, $path) = @_;
	# path must be marked as (S)een
	$path =~ /:2,[A-R]*S[T-Za-z]*\z/ or return;
	my $mime = _path_to_mime($path) or return;
	$self->{config}->each_inbox(sub {
		my ($ibx) = @_;
		eval {
			my $im = _importer_for($self, $ibx);
			$im->remove($mime, 'spam');
			if (my $scrub = $ibx->filter($im)) {
				my $scrubbed = $scrub->scrub($mime, 1);
				$scrubbed or return;
				$scrubbed == REJECT() and return;
				$im->remove($scrubbed, 'spam');
			}
		};
		if ($@) {
			warn "error removing spam at: ", $path,
				" from ", $ibx->{name}, ': ', $@, "\n";
		}
	})
}

sub _try_path {
	my ($self, $path) = @_;
	return unless PublicInbox::InboxWritable::is_maildir_path($path);
	if ($path !~ $self->{mdre}) {
		warn "unrecognized path: $path\n";
		return;
	}
	my $inboxes = $self->{mdmap}->{$1};
	unless ($inboxes) {
		warn "unmappable dir: $1\n";
		return;
	}
	if (!ref($inboxes) && $inboxes eq 'watchspam') {
		return _remove_spam($self, $path);
	}

	my $warn_cb = $SIG{__WARN__} || sub { print STDERR @_ };
	local $SIG{__WARN__} = sub {
		$warn_cb->("path: $path\n");
		$warn_cb->(@_);
	};
	foreach my $ibx (@$inboxes) {
		my $mime = _path_to_mime($path) or next;
		my $im = _importer_for($self, $ibx);

		# any header match means it's eligible for the inbox:
		if (my $watch_hdrs = $ibx->{-watchheaders}) {
			my $ok;
			my $hdr = $mime->header_obj;
			for my $wh (@$watch_hdrs) {
				my $v = $hdr->header_raw($wh->[0]);
				next unless defined($v) && $v =~ $wh->[1];
				$ok = 1;
				last;
			}
			next unless $ok;
		}

		if (my $scrub = $ibx->filter($im)) {
			my $ret = $scrub->scrub($mime) or next;
			$ret == REJECT() and next;
			$mime = $ret;
		}
		$im->add($mime, $self->{spamcheck});
	}
}

sub quit { trigger_scan($_[0], 'quit') }

sub watch {
	my ($self) = @_;
	my $scan = File::Temp->newdir("public-inbox-watch.$$.scan.XXXXXX",
					TMPDIR => 1);
	my $scandir = $self->{scandir} = $scan->dirname;
	my $re = qr!\A$scandir/!;
	my $cb = sub { _try_fsn_paths($self, $re, \@_) };

	# lazy load here, we may support watching via IMAP IDLE
	# in the future...
	require Filesys::Notify::Simple;
	my $fsn = Filesys::Notify::Simple->new([@{$self->{mdir}}, $scandir]);
	$fsn->wait($cb) until $self->{quit};
}

sub trigger_scan {
	my ($self, $base) = @_;
	my $dir = $self->{scandir} or return;
	open my $fh, '>', "$dir/$base" or die "open $dir/$base failed: $!\n";
	close $fh or die "close $dir/$base failed: $!\n";
}

sub scan {
	my ($self, $path) = @_;
	if ($path =~ /quit\z/) {
		%{$self->{opendirs}} = ();
		_done_for_now($self);
		delete $self->{scandir};
		$self->{quit} = 1;
		return;
	}
	# else: $path =~ /(cont|full)\z/
	return if $self->{quit};
	my $max = 10;
	my $opendirs = $self->{opendirs};
	my @dirnames = keys %$opendirs;
	foreach my $dir (@dirnames) {
		my $dh = delete $opendirs->{$dir};
		my $n = $max;
		while (my $fn = readdir($dh)) {
			_try_path($self, "$dir/$fn");
			last if --$n < 0;
		}
		$opendirs->{$dir} = $dh if $n < 0;
	}
	if ($path =~ /full\z/) {
		foreach my $dir (@{$self->{mdir}}) {
			next if $opendirs->{$dir}; # already in progress
			my $ok = opendir(my $dh, $dir);
			unless ($ok) {
				warn "failed to open $dir: $!\n";
				next;
			}
			my $n = $max;
			while (my $fn = readdir($dh)) {
				_try_path($self, "$dir/$fn");
				last if --$n < 0;
			}
			$opendirs->{$dir} = $dh if $n < 0;
		}
	}
	_done_for_now($self);
	# do we have more work to do?
	trigger_scan($self, 'cont') if keys %$opendirs;
}

sub _path_to_mime {
	my ($path) = @_;
	if (open my $fh, '<', $path) {
		local $/;
		my $str = <$fh>;
		$str or return;
		return PublicInbox::MIME->new(\$str);
	} elsif ($!{ENOENT}) {
		return;
	} else {
		warn "failed to open $path: $!\n";
		return;
	}
}

sub _importer_for {
	my ($self, $ibx) = @_;
	my $importers = $self->{importers};
	my $im = $importers->{"$ibx"} ||= $ibx->importer(0);
	if (scalar(keys(%$importers)) > 2) {
		delete $importers->{"$ibx"};
		_done_for_now($self);
	}

	$importers->{"$ibx"} = $im;
}

sub _spamcheck_cb {
	my ($sc) = @_;
	sub {
		my ($mime) = @_;
		my $tmp = '';
		if ($sc->spamcheck($mime, \$tmp)) {
			return PublicInbox::MIME->new(\$tmp);
		}
		warn $mime->header('Message-ID')." failed spam check\n";
		undef;
	}
}

sub is_maildir {
	$_[0] =~ s!\Amaildir:!! or return;
	$_[0] =~ tr!/!/!s;
	$_[0] =~ s!/\z!!;
	$_[0];
}

1;
