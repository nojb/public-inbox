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

# this is public-inbox-httpd-specific
sub mboxgz_blob_cb { # git->cat_async callback
	my ($bref, $oid, $type, $size, $self) = @_;
	my $http = $self->{env}->{'psgix.io'} or return; # client abort
	my $smsg = delete $self->{smsg} or die 'BUG: no smsg';
	if (!defined($oid)) {
		# it's possible to have TOCTOU if an admin runs
		# public-inbox-(edit|purge), just move onto the next message
		return $http->next_step(\&mboxgz_async_next);
	} else {
		$smsg->{blob} eq $oid or die "BUG: $smsg->{blob} != $oid";
	}
	my $eml = PublicInbox::Eml->new($bref);
	$self->zmore(msg_hdr($self, $eml, $smsg->{mid}));

	# PublicInbox::HTTP::{Chunked,Identity}::write
	$self->{http_out}->write($self->translate(msg_body($eml)));

	$http->next_step(\&mboxgz_async_next);
}

# this is public-inbox-httpd-specific
sub mboxgz_async_step ($) {
	my ($self) = @_;
	if (my $smsg = $self->{smsg} = $self->{cb}->($self)) {
		git_async_cat($self->{-inbox}->git, $smsg->{blob},
				\&mboxgz_blob_cb, $self);
	} elsif (my $out = delete $self->{http_out}) {
		$out->write($self->zflush);
		$out->close;
	}
}

# called by PublicInbox::DS::write
sub mboxgz_async_next {
	my ($http) = @_; # PublicInbox::HTTP
	mboxgz_async_step($http->{forward});
}

# called by PublicInbox::HTTP::close, or any other PSGI server
sub close { !!delete($_[0]->{http_out}) }

sub response {
	my ($self, $cb, $res_hdr) = @_;
	$self->{cb} = $cb;
	bless $self, __PACKAGE__;
	if ($self->{env}->{'pi-httpd.async'}) {
		sub {
			my ($wcb) = @_; # -httpd provided write callback
			$self->{http_out} = $wcb->([200, $res_hdr]);
			$self->{env}->{'psgix.io'}->{forward} = $self;
			mboxgz_async_step($self); # start stepping
		};
	} else { # generic PSGI
		[ 200, $res_hdr, $self ];
	}
}

sub mbox_gz {
	my ($self, $cb, $fn) = @_;
	$self->{base_url} = $self->{-inbox}->base_url($self->{env});
	$self->{gz} = PublicInbox::GzipFilter::gzip_or_die();
	$fn = to_filename($fn // 'no-subject');
	$fn = 'no-subject' if $fn eq '';
	# http://www.iana.org/assignments/media-types/application/gzip
	response($self, $cb, [ qw(Content-Type application/gzip),
		'Content-Disposition', "inline; filename=$fn.mbox.gz" ]);
}

# called by Plack::Util::foreach or similar (generic PSGI)
sub getline {
	my ($self) = @_;
	my $cb = $self->{cb} or return;
	while (my $smsg = $cb->($self)) {
		my $eml = $self->{-inbox}->smsg_eml($smsg) or next;
		$self->zmore(msg_hdr($self, $eml, $smsg->{mid}));
		return $self->translate(msg_body($eml));
	}
	# signal that we're done and can return undef next call:
	delete $self->{cb};
	$self->zflush;
}

1;
