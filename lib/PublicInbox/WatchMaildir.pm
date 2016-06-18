# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
package PublicInbox::WatchMaildir;
use strict;
use warnings;
use Email::MIME;
use Email::MIME::ContentType;
$Email::MIME::ContentType::STRICT_PARAMS = 0; # user input is imperfect
use PublicInbox::Git;
use PublicInbox::Import;
use PublicInbox::MDA;
use PublicInbox::Spawn qw(spawn);

sub new {
	my ($class, $config) = @_;
	my (%mdmap, @mdir);
	my $k = 'publicinboxlearn.watchspam';
	if (my $spamdir = $config->{$k}) {
		if ($spamdir =~ s/\Amaildir://) {
			$spamdir =~ s!/+\z!!;
			# skip "new", no MUA has seen it, yet.
			my $cur = "$spamdir/cur";
			push @mdir, $cur;
			$mdmap{$cur} = 'watchspam';
		} else {
			warn "unsupported $k=$spamdir\n";
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
		mdmap => \%mdmap,
		mdir => \@mdir,
		mdre => $mdre,
		importers => {},
	}, $class;
}

sub _done_for_now {
	$_->done foreach values %{$_[0]->{importers}};
}

sub _try_fsn_paths {
	my ($self, $paths) = @_;
	_try_path($self, $_->{path}) foreach @$paths;
	_done_for_now($self);
}

sub _check_spam {
	my ($self, $path) = @_;
	my $mime = _path_to_mime($path) or return;
	_force_mid($mime);
	foreach my $inbox (values %{$self->{mdmap}}) {
		next unless ref $inbox;
		my $im = _importer_for($self, $inbox);
		$im->remove($mime);
		if (my $scrub = _scrubber_for($inbox)) {
			my $scrubbed = $scrub->scrub($mime) or next;
			$im->remove($scrubbed);
		}
	}
}

# used to hash the relevant portions of a message when there are conflicts
sub _hash_mime2 {
	my ($mime) = @_;
	require Digest::SHA;
	my $dig = Digest::SHA->new('SHA-1');
	$dig->add($mime->header_obj->header_raw('Subject'));
	$dig->add($mime->body_raw);
	$dig->hexdigest;
}

sub _force_mid {
	my ($mime) = @_;
	# probably a bad idea, but we inject a Message-Id if
	# one is missing, here..
	my $mid = $mime->header_obj->header_raw('Message-Id');
	if (!defined $mid || $mid =~ /\A\s*\z/) {
		$mid = '<' . _hash_mime2($mime) . '@generated>';
		$mime->header_set('Message-Id', $mid);
	}
}

sub _try_path {
	my ($self, $path) = @_;
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
		return _check_spam($self, $path);
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
		$mime = $scrub->scrub($mime) or return;
	}

	_force_mid($mime);
	$im->add($mime);
}

sub watch {
	my ($self) = @_;
	my $cb = sub { _try_fsn_paths($self, \@_) };
	my $mdir = $self->{mdir};

	require Filesys::Notify::Simple;
	my $watcher = Filesys::Notify::Simple->new($mdir);
	$watcher->wait($cb) while (1);
}

sub scan {
	my ($self) = @_;
	my $mdir = $self->{mdir};
	foreach my $dir (@$mdir) {
		my $ok = opendir(my $dh, $dir);
		unless ($ok) {
			warn "failed to open $dir: $!\n";
			next;
		}
		while (my $fn = readdir($dh)) {
			next unless $fn =~ /\A[a-zA-Z0-9][\w:,=\.]+\z/;
			$fn = "$dir/$fn";
			if (-f $fn) {
				_try_path($self, $fn);
			} else {
				warn "not a file: $fn\n";
			}
		}
		closedir $dh;
	}
	_done_for_now($self);
}

sub _path_to_mime {
	my ($path) = @_;
	if (open my $fh, '<', $path) {
		local $/;
		my $str = <$fh>;
		$str or return;
		return Email::MIME->new(\$str);
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
		my $git = $inbox->git;
		my $name = $inbox->{name};
		my $addr = $inbox->{-primary_address};
		PublicInbox::Import->new($git, $name, $addr);
	};
	$self->{importers}->{"$im"} = $im;
}

sub _scrubber_for {
	my ($inbox) = @_;
	my $f = $inbox->{filter};
	if ($f && $f =~ /::/) {
		eval "require $f";
		if ($@) {
			warn $@;
		} else {
			return $f->new;
		}
	}
	undef;
}

1;
