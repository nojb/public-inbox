# Copyright (C) 2016-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# ref: https://cr.yp.to/proto/maildir.html
#	http://wiki2.dovecot.org/MailboxFormat/Maildir
package PublicInbox::WatchMaildir;
use strict;
use warnings;
use PublicInbox::MIME;
use PublicInbox::Git;
use PublicInbox::Import;
use PublicInbox::MDA;
use PublicInbox::Spawn qw(spawn);
use File::Temp qw//;

sub new {
	my ($class, $config) = @_;
	my (%mdmap, @mdir, $spamc, $spamdir);

	# "publicinboxwatch" is the documented namespace
	# "publicinboxlearn" is legacy but may be supported
	# indefinitely...
	foreach my $pfx (qw(publicinboxwatch publicinboxlearn)) {
		my $k = "$pfx.watchspam";
		if (my $dir = $config->{$k}) {
			if ($dir =~ s/\Amaildir://) {
				$dir =~ s!/+\z!!;
				# skip "new", no MUA has seen it, yet.
				my $cur = "$dir/cur";
				$spamdir = $cur;
				push @mdir, $cur;
				$mdmap{$cur} = 'watchspam';
			} else {
				warn "unsupported $k=$dir\n";
			}
		}
	}

	my $k = 'publicinboxwatch.spamcheck';
	my $spamcheck = $config->{$k};
	if ($spamcheck) {
		if ($spamcheck eq 'spamc') {
			$spamcheck = 'PublicInbox::Spamcheck::Spamc';
		}
		if ($spamcheck =~ /::/) {
			eval "require $spamcheck";
			$spamcheck = _spamcheck_cb($spamcheck->new);
		} else {
			warn "unsupported $k=$spamcheck\n";
			$spamcheck = undef;
		}
	}
	foreach $k (keys %$config) {
		$k =~ /\Apublicinbox\.([^\.]+)\.watch\z/ or next;
		my $name = $1;
		my $watch = $config->{$k};
		if ($watch =~ s/\Amaildir://) {
			$watch =~ s!/+\z!!;
			my $inbox = $config->lookup_name($name);
			if (my $wm = $inbox->{watchheader}) {
				my ($k, $v) = split(/:/, $wm, 2);
				$inbox->{-watchheader} = [ $k, qr/\Q$v\E/ ];
			}
			my $new = "$watch/new";
			my $cur = "$watch/cur";
			push @mdir, $new, $cur;
			die "$new already in use\n" if $mdmap{$new};
			die "$cur already in use\n" if $mdmap{$cur};
			$mdmap{$new} = $mdmap{$cur} = $inbox;
		} else {
			warn "watch unsupported: $k=$watch\n";
		}
	}
	return unless @mdir;

	my $mdre = join('|', map { quotemeta($_) } @mdir);
	$mdre = qr!\A($mdre)/!;
	bless {
		spamcheck => $spamcheck,
		spamdir => $spamdir,
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
			if (my $scrub = _scrubber_for($ibx)) {
				my $scrubbed = $scrub->scrub($mime) or return;
				$scrubbed == 100 and return;
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
	my @p = split(m!/+!, $path);
	return if $p[-1] !~ /\A[a-zA-Z0-9][\-\w:,=\.]+\z/;
	if ($p[-1] =~ /:2,([A-Z]+)\z/i) {
		my $flags = $1;
		return if $flags =~ /[DT]/; # no [D]rafts or [T]rashed mail
	}
	return unless -f $path;
	if ($path !~ $self->{mdre}) {
		warn "unrecognized path: $path\n";
		return;
	}
	my $inbox = $self->{mdmap}->{$1};
	unless ($inbox) {
		warn "unmappable dir: $1\n";
		return;
	}
	if (!ref($inbox) && $inbox eq 'watchspam') {
		return _remove_spam($self, $path);
	}
	my $im = _importer_for($self, $inbox);
	my $mime = _path_to_mime($path) or return;
	$mime->header_set($_) foreach @PublicInbox::MDA::BAD_HEADERS;
	my $wm = $inbox->{-watchheader};
	if ($wm) {
		my $v = $mime->header_obj->header_raw($wm->[0]);
		return unless ($v && $v =~ $wm->[1]);
	}
	if (my $scrub = _scrubber_for($inbox)) {
		my $ret = $scrub->scrub($mime) or return;
		$ret == 100 and return;
		$mime = $ret;
	}

	$im->add($mime, $self->{spamcheck});
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
	my ($self, $inbox) = @_;
	my $im = $inbox->{-import} ||= eval {
		my $v = $inbox->{version} || 1;
		if ($v == 2) {
			eval { require PublicInbox::V2Writable };
			die "v2 not supported: $@\n" if $@;
			my $v2w = PublicInbox::V2Writable->new($inbox);
			$v2w->{parallel} = 0;
			$v2w;
		} elsif ($v == 1) {
			my $git = $inbox->git;
			my $name = $inbox->{name};
			my $addr = $inbox->{-primary_address};
			PublicInbox::Import->new($git, $name, $addr, $inbox);
		} else {
			die "unsupported inbox version: $v\n";
		}
	};

	my $importers = $self->{importers};
	if (scalar(keys(%$importers)) > 2) {
		delete $importers->{"$im"};
		_done_for_now($self);
	}

	$importers->{"$im"} = $im;
}

sub _scrubber_for {
	my ($inbox) = @_;
	my $f = $inbox->{filter};
	if ($f && $f =~ /::/) {
		my @args = (-inbox => $inbox);
		# basic line splitting, only
		# Perhaps we can have proper quote splitting one day...
		($f, @args) = split(/\s+/, $f) if $f =~ /\s+/;

		eval "require $f";
		if ($@) {
			warn $@;
		} else {
			# e.g: PublicInbox::Filter::Vger->new(@args)
			return $f->new(@args);
		}
	}
	undef;
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

1;
