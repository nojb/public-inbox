# Copyright (C) 2015-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
package PublicInbox::MboxGz;
use strict;
use parent 'PublicInbox::GzipFilter';
use PublicInbox::Eml;
use PublicInbox::Hval qw/to_filename/;
use PublicInbox::Mbox;
use PublicInbox::GitAsyncCat;
*msg_hdr = \&PublicInbox::Mbox::msg_hdr;
*msg_body = \&PublicInbox::Mbox::msg_body;

sub new {
	my ($class, $ctx, $cb) = @_;
	$ctx->{base_url} = $ctx->{-inbox}->base_url($ctx->{env});
	bless {
		gz => PublicInbox::GzipFilter::gzip_or_die(),
		cb => $cb,
		ctx => $ctx
	}, $class;
}

# this is public-inbox-httpd-specific
sub mboxgz_blob_cb { # git->cat_async callback
	my ($bref, $oid, $type, $size, $self) = @_;
	my $http = $self->{ctx}->{env}->{'psgix.io'} or return; # client abort
	my $smsg = delete $self->{smsg} or die 'BUG: no smsg';
	if (!defined($oid)) {
		# it's possible to have TOCTOU if an admin runs
		# public-inbox-(edit|purge), just move onto the next message
		return $http->next_step(\&async_next);
	} else {
		$smsg->{blob} eq $oid or die "BUG: $smsg->{blob} != $oid";
	}
	$self->zmore(msg_hdr($self->{ctx},
				PublicInbox::Eml->new($bref)->header_obj,
				$smsg->{mid}));

	# PublicInbox::HTTP::{Chunked,Identity}::write
	$self->{http_out}->write($self->translate(msg_body($$bref)));

	$http->next_step(\&async_next);
}

# this is public-inbox-httpd-specific
sub async_step ($) {
	my ($self) = @_;
	if (my $smsg = $self->{smsg} = $self->{cb}->($self->{ctx})) {
		git_async_cat($self->{ctx}->{-inbox}->git, $smsg->{blob},
				\&mboxgz_blob_cb, $self);
	} elsif (my $out = delete $self->{http_out}) {
		$out->write($self->zflush);
		$out->close;
	}
}

# called by PublicInbox::DS::write
sub async_next {
	my ($http) = @_; # PublicInbox::HTTP
	async_step($http->{forward});
}

# called by PublicInbox::HTTP::close, or any other PSGI server
sub close { !!delete($_[0]->{http_out}) }

sub response {
	my ($class, $ctx, $cb, $fn) = @_;
	my $self = $class->new($ctx, $cb);
	# http://www.iana.org/assignments/media-types/application/gzip
	$fn = defined($fn) && $fn ne '' ? to_filename($fn) : 'no-subject';
	my $h = [ qw(Content-Type application/gzip),
		'Content-Disposition', "inline; filename=$fn.mbox.gz" ];
	if ($ctx->{env}->{'pi-httpd.async'}) {
		sub {
			my ($wcb) = @_; # -httpd provided write callback
			$self->{http_out} = $wcb->([200, $h]);
			$self->{ctx}->{env}->{'psgix.io'}->{forward} = $self;
			async_step($self); # start stepping
		};
	} else { # generic PSGI
		[ 200, $h, $self ];
	}
}

# called by Plack::Util::foreach or similar (generic PSGI)
sub getline {
	my ($self) = @_;
	my $ctx = $self->{ctx} or return;
	while (my $smsg = $self->{cb}->($ctx)) {
		my $mref = $ctx->{-inbox}->msg_by_smsg($smsg) or next;
		my $h = PublicInbox::Eml->new($mref)->header_obj;
		$self->zmore(msg_hdr($ctx, $h, $smsg->{mid}));
		return $self->translate(msg_body($$mref));
	}
	# signal that we're done and can return undef next call:
	delete $self->{ctx};
	$self->zflush;
}

1;
