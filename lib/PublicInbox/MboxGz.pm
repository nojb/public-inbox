# Copyright (C) 2015-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
package PublicInbox::MboxGz;
use strict;
use warnings;
use Email::Simple;
use PublicInbox::Hval qw/to_filename/;
use PublicInbox::Mbox;
use IO::Compress::Gzip;

sub new {
	my ($class, $ctx, $cb) = @_;
	my $buf = '';
	$ctx->{base_url} = $ctx->{-inbox}->base_url($ctx->{env});
	bless {
		buf => \$buf,
		gz => IO::Compress::Gzip->new(\$buf, Time => 0),
		cb => $cb,
		ctx => $ctx,
	}, $class;
}

sub response {
	my ($class, $ctx, $cb, $fn) = @_;
	my $body = $class->new($ctx, $cb);
	# http://www.iana.org/assignments/media-types/application/gzip
	my @h = qw(Content-Type application/gzip);
	if ($fn) {
		$fn = to_filename($fn);
		push @h, 'Content-Disposition', "inline; filename=$fn.mbox.gz";
	}
	[ 200, \@h, $body ];
}

# called by Plack::Util::foreach or similar
sub getline {
	my ($self) = @_;
	my $ctx = $self->{ctx} or return;
	my $gz = $self->{gz};
	while (my $smsg = $self->{cb}->()) {
		my $mref = $ctx->{-inbox}->msg_by_smsg($smsg) or next;
		my $h = Email::Simple->new($mref)->header_obj;
		$gz->write(PublicInbox::Mbox::msg_hdr($ctx, $h, $smsg->{mid}));
		$gz->write(PublicInbox::Mbox::msg_body($$mref));

		my $bref = $self->{buf};
		if (length($$bref) >= 8192) {
			my $ret = $$bref; # copy :<
			${$self->{buf}} = '';
			return $ret;
		}

		# be fair to other clients on public-inbox-httpd:
		return '';
	}
	delete($self->{gz})->close;
	# signal that we're done and can return undef next call:
	delete $self->{ctx};
	${delete $self->{buf}};
}

sub close {} # noop

1;
