# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# In public-inbox <=1.5.0, public-inbox-httpd favored "getline"
# response bodies to take a "pull"-based approach to feeding
# slow clients (as opposed to a more common "push" model).
#
# In newer versions, public-inbox-httpd supports a backpressure-aware
# pull/push model which also accounts for slow git blob storage.
# async_next callbacks only run when the DS {wbuf} is drained
# async_eml callbacks only run when a blob arrives from git.
#
# We continue to support getline+close for generic PSGI servers.
package PublicInbox::GzipFilter;
use strict;
use parent qw(Exporter);
use Compress::Raw::Zlib qw(Z_OK);
use PublicInbox::CompressNoop;
use PublicInbox::Eml;
use PublicInbox::GitAsyncCat;

our @EXPORT_OK = qw(gzf_maybe);
my %OPT = (-WindowBits => 15 + 16, -AppendOutput => 1);
my @GZIP_HDRS = qw(Vary Accept-Encoding Content-Encoding gzip);

sub new { bless {}, shift } # qspawn filter

# for Qspawn if using $env->{'pi-httpd.async'}
sub attach {
	my ($self, $http_out) = @_;
	$self->{http_out} = $http_out; # PublicInbox::HTTP::{Chunked,Identity}
	$self
}

sub gz_or_noop {
	my ($res_hdr, $env) = @_;
	if (($env->{HTTP_ACCEPT_ENCODING} // '') =~ /\bgzip\b/) {
		$env->{'plack.skip-deflater'} = 1;
		push @$res_hdr, @GZIP_HDRS;
		gzip_or_die();
	} else {
		PublicInbox::CompressNoop::new();
	}
}

sub gzf_maybe ($$) { bless { gz => gz_or_noop(@_) }, __PACKAGE__ }

sub psgi_response {
	my ($self, $code, $res_hdr) = @_;
	my $env = $self->{env};
	$self->{gz} //= gz_or_noop($res_hdr, $env);
	if ($env->{'pi-httpd.async'}) {
		my $http = $env->{'psgix.io'}; # PublicInbox::HTTP
		$http->{forward} = $self;
		sub {
			my ($wcb) = @_; # -httpd provided write callback
			$self->{http_out} = $wcb->([$code, $res_hdr]);
			$self->can('async_next')->($http); # start stepping
		};
	} else { # generic PSGI code path
		[ $code, $res_hdr, $self ];
	}
}

sub qsp_maybe ($$) {
	my ($res_hdr, $env) = @_;
	return if ($env->{HTTP_ACCEPT_ENCODING} // '') !~ /\bgzip\b/;
	my $hdr = join("\n", @$res_hdr);
	return if $hdr !~ m!^Content-Type\n
				(?:(?:text/(?:html|plain))|
				application/atom\+xml)\b!ixsm;
	return if $hdr =~ m!^Content-Encoding\ngzip\n!smi;
	return if $hdr =~ m!^Content-Length\n[0-9]+\n!smi;
	return if $hdr =~ m!^Transfer-Encoding\n!smi;
	# in case Plack::Middleware::Deflater is loaded:
	return if $env->{'plack.skip-deflater'}++;
	push @$res_hdr, @GZIP_HDRS;
	bless {}, __PACKAGE__;
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
		my $err = $gz->flush($zbuf);
		die "gzip->flush: $err" if $err != Z_OK;
		$zbuf;
	}
}

sub write {
	# my $ret = bytes::length($_[1]); # XXX does anybody care?
	$_[0]->{http_out}->write(translate($_[0], $_[1]));
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
	$err = $gz->flush($zbuf);
	die "gzip->flush: $err" if $err != Z_OK;
	$zbuf;
}

sub close {
	my ($self) = @_;
	if (my $http_out = delete $self->{http_out}) {
		$http_out->write(zflush($self));
		$http_out->close;
	}
}

sub bail  {
	my $self = shift;
	if (my $env = $self->{env}) {
		eval { $env->{'psgi.errors'}->print(@_, "\n") };
		warn("E: error printing to psgi.errors: $@", @_) if $@;
		my $http = $env->{'psgix.io'} or return; # client abort
		eval { $http->close }; # should hit our close
		warn "E: error in http->close: $@" if $@;
		eval { $self->close }; # just in case...
		warn "E: error in self->close: $@" if $@;
	} else {
		warn @_, "\n";
	}
}

# this is public-inbox-httpd-specific
sub async_blob_cb { # git->cat_async callback
	my ($bref, $oid, $type, $size, $self) = @_;
	my $http = $self->{env}->{'psgix.io'};
	$http->{forward} or return; # client aborted
	my $smsg = $self->{smsg} or bail($self, 'BUG: no smsg');
	if (!defined($oid)) {
		# it's possible to have TOCTOU if an admin runs
		# public-inbox-(edit|purge), just move onto the next message
		warn "E: $smsg->{blob} missing in $self->{ibx}->{inboxdir}\n";
		return $http->next_step($self->can('async_next'));
	}
	$smsg->{blob} eq $oid or bail($self, "BUG: $smsg->{blob} != $oid");
	eval { $self->async_eml(PublicInbox::Eml->new($bref)) };
	bail($self, "E: async_eml: $@") if $@;
	if ($self->{-low_prio}) {
		push(@{$self->{www}->{-low_prio_q}}, $self) == 1 and
				PublicInbox::DS::requeue($self->{www});
	} else {
		$http->next_step($self->can('async_next'));
	}
}

sub smsg_blob {
	my ($self, $smsg) = @_;
	ibx_async_cat($self->{ibx}, $smsg->{blob}, \&async_blob_cb, $self);
}

1;
