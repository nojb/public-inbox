# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# corner case tests for the generic PSGI server
# Usage: plackup [OPTIONS] /path/to/this/file
use v5.12;
use warnings;
use Plack::Builder;
require Digest::SHA;
my $pi_config = $ENV{PI_CONFIG} // 'unset'; # capture ASAP
my $app = sub {
	my ($env) = @_;
	my $path = $env->{PATH_INFO};
	my $in = $env->{'psgi.input'};
	my $actual = -s $in;
	my $code = 500;
	my $h = [ 'Content-Type' => 'text/plain' ];
	my $body = [];
	if ($path eq '/sha1') {
		my $sha1 = Digest::SHA->new('SHA-1');
		my $buf;
		while (1) {
			my $r = $in->read($buf, 4096);
			die "read err: $!" unless defined $r;
			last if $r == 0;
			$sha1->add($buf);
		}
		$code = 200;
		push @$body, $sha1->hexdigest;
	} elsif (my $fifo = $env->{HTTP_X_CHECK_FIFO}) {
		if ($path eq '/slow-header') {
			return sub {
				open my $f, '<', $fifo or
						die "open $fifo: $!\n";
				local $/ = "\n";
				my @r = <$f>;
				$_[0]->([200, $h, \@r ]);
			};
		} elsif ($path eq '/slow-body') {
			return sub {
				my $fh = $_[0]->([200, $h]);
				open my $f, '<', $fifo or
						die "open $fifo: $!\n";
				local $/ = "\n";
				while (defined(my $l = <$f>)) {
					$fh->write($l);
				}
				$fh->close;
			};
		}
	} elsif ($path eq '/host-port') {
		$code = 200;
		push @$body, "$env->{REMOTE_ADDR} $env->{REMOTE_PORT}";
	} elsif ($path eq '/callback') {
		return sub {
			my ($res) = @_;
			my $buf = "hello world\n";
			push @$h, 'Content-Length', length($buf);
			my $fh = $res->([200, $h]);
			$fh->write($buf);
			$fh->close;
		}
	} elsif ($path eq '/empty') {
		$code = 200;
	} elsif ($path eq '/getline-die') {
		$code = 200;
		$body = Plack::Util::inline_object(
			getline => sub { die 'GETLINE FAIL' },
			close => sub { die 'CLOSE FAIL' },
		);
	} elsif ($path eq '/close-die') {
		$code = 200;
		$body = Plack::Util::inline_object(
			getline => sub { undef },
			close => sub { die 'CLOSE FAIL' },
		);
	} elsif ($path eq '/async-big') {
		require PublicInbox::Qspawn;
		open my $null, '>', '/dev/null' or die;
		my $rdr = { 2 => fileno($null) };
		my $cmd = [qw(dd if=/dev/zero count=30 bs=1024k)];
		my $qsp = PublicInbox::Qspawn->new($cmd, undef, $rdr);
		return $qsp->psgi_return($env, undef, sub {
			my ($r, $bref) = @_;
			# make $rd_hdr retry sysread + $parse_hdr in Qspawn:
			return until length($$bref) > 8000;
			close $null;
			[ 200, [ qw(Content-Type application/octet-stream) ]];
		});
	} elsif ($path eq '/psgi-return-gzip') {
		require PublicInbox::Qspawn;
		require PublicInbox::GzipFilter;
		my $cmd = [qw(echo hello world)];
		my $qsp = PublicInbox::Qspawn->new($cmd);
		$env->{'qspawn.filter'} = PublicInbox::GzipFilter->new;
		return $qsp->psgi_return($env, undef, sub {
			[ 200, [ qw(Content-Type application/octet-stream)]]
		});
	} elsif ($path eq '/psgi-return-compressible') {
		require PublicInbox::Qspawn;
		my $cmd = [qw(echo goodbye world)];
		my $qsp = PublicInbox::Qspawn->new($cmd);
		return $qsp->psgi_return($env, undef, sub {
			[200, [qw(Content-Type text/plain)]]
		});
	} elsif ($path eq '/psgi-return-enoent') {
		require PublicInbox::Qspawn;
		my $cmd = [ 'this-better-not-exist-in-PATH'.rand ];
		my $qsp = PublicInbox::Qspawn->new($cmd);
		return $qsp->psgi_return($env, undef, sub {
			[ 200, [ qw(Content-Type application/octet-stream)]]
		});
	} elsif ($path eq '/pid') {
		$code = 200;
		push @$body, "$$\n";
	} elsif ($path eq '/url_scheme') {
		$code = 200;
		push @$body, $env->{'psgi.url_scheme'}
	} elsif ($path eq '/PI_CONFIG') {
		$code = 200;
		push @$body, $pi_config; # show value at ->refresh_groups
	}
	[ $code, $h, $body ]
};

builder {
	enable 'ContentLength';
	enable 'Head';
	$app;
}
