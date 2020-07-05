# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Qspawn filter
package PublicInbox::GzipFilter;
use strict;
use parent qw(Exporter);
use Compress::Raw::Zlib qw(Z_FINISH Z_OK);
our @EXPORT_OK = qw(gzf_maybe);
my %OPT = (-WindowBits => 15 + 16, -AppendOutput => 1);
my @GZIP_HDRS = qw(Vary Accept-Encoding Content-Encoding gzip);

sub new { bless {}, shift }

# for Qspawn if using $env->{'pi-httpd.async'}
sub attach {
	my ($self, $fh) = @_;
	$self->{fh} = $fh;
	$self
}

# returns `0' and not `undef' on failure (see Www*Stream)
sub gzf_maybe ($$) {
	my ($res_hdr, $env) = @_;
	return 0 if (($env->{HTTP_ACCEPT_ENCODING}) // '') !~ /\bgzip\b/;
	my ($gz, $err) = Compress::Raw::Zlib::Deflate->new(%OPT);
	return 0 if $err != Z_OK;

	# in case Plack::Middleware::Deflater is loaded:
	$env->{'plack.skip-deflater'} = 1;
	push @$res_hdr, @GZIP_HDRS;
	bless { gz => $gz }, __PACKAGE__;
}

sub gzip_or_die () {
	my ($gz, $err) = Compress::Raw::Zlib::Deflate->new(%OPT);
	$err == Z_OK or die "Deflate->new failed: $err";
	$gz;
}

# for GetlineBody (via Qspawn) when NOT using $env->{'pi-httpd.async'}
# Also used for ->getline callbacks
sub translate ($$) {
	my $self = $_[0]; # $_[1] => input

	# allocate the zlib context lazily here, instead of in ->new.
	# Deflate contexts are memory-intensive and this object may
	# be sitting in the Qspawn limiter queue for a while.
	my $gz = $self->{gz} //= gzip_or_die();
	my $zbuf = delete($self->{zbuf});
	if (defined $_[1]) { # my $buf = $_[1];
		my $err = $gz->deflate($_[1], $zbuf);
		die "gzip->deflate: $err" if $err != Z_OK;
		return $zbuf if length($zbuf) >= 8192;

		$self->{zbuf} = $zbuf;
		'';
	} else { # undef == EOF
		my $err = $gz->flush($zbuf, Z_FINISH);
		die "gzip->flush: $err" if $err != Z_OK;
		$zbuf;
	}
}

sub write {
	# my $ret = bytes::length($_[1]); # XXX does anybody care?
	$_[0]->{fh}->write(translate($_[0], $_[1]));
}

# similar to ->translate; use this when we're sure we know we have
# more data to buffer after this
sub zmore {
	my $self = $_[0]; # $_[1] => input
	my $err = $self->{gz}->deflate($_[1], $self->{zbuf});
	die "gzip->deflate: $err" if $err != Z_OK;
	undef;
}

# flushes and returns the final bit of gzipped data
sub zflush ($;$) {
	my $self = $_[0]; # $_[1] => final input (optional)
	my $zbuf = delete $self->{zbuf};
	my $gz = delete $self->{gz};
	my $err;
	if (defined $_[1]) {
		$err = $gz->deflate($_[1], $zbuf);
		die "gzip->deflate: $err" if $err != Z_OK;
	}
	$err = $gz->flush($zbuf, Z_FINISH);
	die "gzip->flush: $err" if $err != Z_OK;
	$zbuf;
}

sub close {
	my ($self) = @_;
	my $fh = delete $self->{fh};
	$fh->write(zflush($self));
	$fh->close;
}

1;
