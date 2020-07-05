# Copyright (C) 2015-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
package PublicInbox::MboxGz;
use strict;
use parent 'PublicInbox::GzipFilter';
use PublicInbox::Eml;
use PublicInbox::Hval qw/to_filename/;
use PublicInbox::Mbox;

sub new {
	my ($class, $ctx, $cb) = @_;
	$ctx->{base_url} = $ctx->{-inbox}->base_url($ctx->{env});
	bless {
		gz => PublicInbox::GzipFilter::gzip_or_die(),
		cb => $cb,
		ctx => $ctx
	}, $class;
}

sub response {
	my ($class, $ctx, $cb, $fn) = @_;
	my $body = $class->new($ctx, $cb);
	# http://www.iana.org/assignments/media-types/application/gzip
	$fn = defined($fn) && $fn ne '' ? to_filename($fn) : 'no-subject';
	my $h = [ qw(Content-Type application/gzip),
		'Content-Disposition', "inline; filename=$fn.mbox.gz" ];
	[ 200, $h, $body ];
}

# called by Plack::Util::foreach or similar
sub getline {
	my ($self) = @_;
	my $ctx = $self->{ctx} or return;
	while (my $smsg = $self->{cb}->($ctx)) {
		my $mref = $ctx->{-inbox}->msg_by_smsg($smsg) or next;
		my $h = PublicInbox::Eml->new($mref)->header_obj;
		$self->zmore(
			PublicInbox::Mbox::msg_hdr($ctx, $h, $smsg->{mid})
		);
		return $self->translate(PublicInbox::Mbox::msg_body($$mref));
	}
	# signal that we're done and can return undef next call:
	delete $self->{ctx};
	$self->zflush;
}

sub close {} # noop

1;
