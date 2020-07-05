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
		return $http->next_step(\&async_next);
	} else {
		$smsg->{blob} eq $oid or die "BUG: $smsg->{blob} != $oid";
	}
	$self->zmore(msg_hdr($self,
				PublicInbox::Eml->new($bref)->header_obj,
				$smsg->{mid}));

	# PublicInbox::HTTP::{Chunked,Identity}::write
	$self->{http_out}->write($self->translate(msg_body($$bref)));

	$http->next_step(\&async_next);
}

# this is public-inbox-httpd-specific
sub async_step ($) {
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
sub async_next {
	my ($http) = @_; # PublicInbox::HTTP
	async_step($http->{forward});
}

# called by PublicInbox::HTTP::close, or any other PSGI server
sub close { !!delete($_[0]->{http_out}) }

sub response {
	my ($class, $self, $cb, $fn) = @_;
	$self->{base_url} = $self->{-inbox}->base_url($self->{env});
	$self->{cb} = $cb;
	$self->{gz} = PublicInbox::GzipFilter::gzip_or_die();
	bless $self, $class;
	# http://www.iana.org/assignments/media-types/application/gzip
	$fn = defined($fn) && $fn ne '' ? to_filename($fn) : 'no-subject';
	my $h = [ qw(Content-Type application/gzip),
		'Content-Disposition', "inline; filename=$fn.mbox.gz" ];
	if ($self->{env}->{'pi-httpd.async'}) {
		sub {
			my ($wcb) = @_; # -httpd provided write callback
			$self->{http_out} = $wcb->([200, $h]);
			$self->{env}->{'psgix.io'}->{forward} = $self;
			async_step($self); # start stepping
		};
	} else { # generic PSGI
		[ 200, $h, $self ];
	}
}

# called by Plack::Util::foreach or similar (generic PSGI)
sub getline {
	my ($self) = @_;
	my $cb = $self->{cb} or return;
	while (my $smsg = $cb->($self)) {
		my $mref = $self->{-inbox}->msg_by_smsg($smsg) or next;
		my $h = PublicInbox::Eml->new($mref)->header_obj;
		$self->zmore(msg_hdr($self, $h, $smsg->{mid}));
		return $self->translate(msg_body($$mref));
	}
	# signal that we're done and can return undef next call:
	delete $self->{cb};
	$self->zflush;
}

1;
