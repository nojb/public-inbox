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

sub new {
	my ($class, $config) = @_;
	my (%mdmap, @mdir);
	foreach my $k (keys %$config) {
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
			$mdmap{$new} = $inbox;
			$mdmap{$cur} = $inbox;
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

sub _try_fsn_paths {
	my ($self, $paths) = @_;
	_try_path($self, $_->{path}) foreach @$paths;
	$_->done foreach values %{$self->{importers}};
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
	my $im = $inbox->{-import} ||= eval {
		my $git = $inbox->git;
		my $name = $inbox->{name};
		my $addr = $inbox->{-primary_address};
		PublicInbox::Import->new($git, $name, $addr);
	};
	$self->{importers}->{"$im"} = $im;
	my $mime;
	if (open my $fh, '<', $path) {
		local $/;
		my $str = <$fh>;
		$str or return;
		$mime = Email::MIME->new(\$str);
	} elsif ($!{ENOENT}) {
		return;
	} else {
		warn "failed to open $path: $!\n";
		return;
	}

	$mime->header_set($_) foreach @PublicInbox::MDA::BAD_HEADERS;
	my $wm = $inbox->{-watchheader};
	if ($wm) {
		my $v = $mime->header_obj->header_raw($wm->[0]);
		unless ($v && $v =~ $wm->[1]) {
			warn "$wm->[0] failed to match $wm->[1]\n";
			return;
		}
	}
	my $f = $inbox->{filter};
	if ($f && $f =~ /::/) {
		eval "require $f";
		if ($@) {
			warn $@;
		} else {
			$f = $f->new;
			$mime = $f->scrub($mime);
		}
	}
	$mime or return;
	my $mid = $mime->header_obj->header_raw('Message-Id');
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
}

1;
