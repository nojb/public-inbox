# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
package PublicInbox::MboxGz;
use strict;
use parent 'PublicInbox::GzipFilter';
use PublicInbox::Eml;
use PublicInbox::Hval qw/to_filename/;
use PublicInbox::Mbox;
*msg_hdr = \&PublicInbox::Mbox::msg_hdr;
*msg_body = \&PublicInbox::Mbox::msg_body;

sub async_next ($) {
	my ($http) = @_; # PublicInbox::HTTP
	my $ctx = $http->{forward} or return;
	eval {
		$ctx->{smsg} = $ctx->{cb}->($ctx) or return $ctx->close;
		$ctx->smsg_blob($ctx->{smsg});
	};
	warn "E: $@" if $@;
}

sub mbox_gz {
	my ($self, $cb, $fn) = @_;
	$self->{cb} = $cb;
	$self->{gz} = PublicInbox::GzipFilter::gzip_or_die();
	$fn = to_filename($fn // '') // 'no-subject';
	# http://www.iana.org/assignments/media-types/application/gzip
	bless $self, __PACKAGE__;
	my $res_hdr = [ 'Content-Type' => 'application/gzip',
		'Content-Disposition' => "inline; filename=$fn.mbox.gz" ];
	$self->psgi_response(200, $res_hdr);
}

# called by Plack::Util::foreach or similar (generic PSGI)
sub getline {
	my ($self) = @_;
	my $cb = $self->{cb} or return;
	while (my $smsg = $cb->($self)) {
		my $eml = $self->{ibx}->smsg_eml($smsg) or next;
		return $self->translate(msg_hdr($self, $eml), msg_body($eml));
	}
	# signal that we're done and can return undef next call:
	delete $self->{cb};
	$self->zflush;
}

no warnings 'once';
*async_eml = \&PublicInbox::Mbox::async_eml;
1;
