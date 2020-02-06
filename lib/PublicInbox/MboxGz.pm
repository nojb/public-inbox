# Copyright (C) 2015-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
package PublicInbox::MboxGz;
use strict;
use warnings;
use Email::Simple;
use PublicInbox::Hval qw/to_filename/;
use PublicInbox::Mbox;
use Compress::Raw::Zlib qw(Z_FINISH Z_OK);
my %OPT = (-WindowBits => 15 + 16, -AppendOutput => 1);

sub new {
	my ($class, $ctx, $cb) = @_;
	$ctx->{base_url} = $ctx->{-inbox}->base_url($ctx->{env});
	my ($gz, $err) = Compress::Raw::Zlib::Deflate->new(%OPT);
	$err == Z_OK or die "Deflate->new failed: $err";
	bless { gz => $gz, cb => $cb, ctx => $ctx }, $class;
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

sub gzip_fail ($$) {
	my ($ctx, $err) = @_;
	$ctx->{env}->{'psgi.errors'}->print("deflate failed: $err\n");
	'';
}

# called by Plack::Util::foreach or similar
sub getline {
	my ($self) = @_;
	my $ctx = $self->{ctx} or return;
	my $gz = $self->{gz};
	my $buf = delete($self->{buf});
	while (my $smsg = $self->{cb}->($ctx)) {
		my $mref = $ctx->{-inbox}->msg_by_smsg($smsg) or next;
		my $h = Email::Simple->new($mref)->header_obj;

		my $err = $gz->deflate(
			PublicInbox::Mbox::msg_hdr($ctx, $h, $smsg->{mid}),
		        $buf);
		return gzip_fail($ctx, $err) if $err != Z_OK;

		$err = $gz->deflate(PublicInbox::Mbox::msg_body($$mref), $buf);
		return gzip_fail($ctx, $err) if $err != Z_OK;

		return $buf if length($buf) >= 8192;

		# be fair to other clients on public-inbox-httpd:
		$self->{buf} = $buf;
		return '';
	}
	# signal that we're done and can return undef next call:
	delete $self->{ctx};
	my $err = $gz->flush($buf, Z_FINISH);
	($err == Z_OK) ? $buf : gzip_fail($ctx, $err);
}

sub close {} # noop

1;
