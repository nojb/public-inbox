# Copyright (C) 2016-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# For retrieving attachments from messages in the WWW interface
package PublicInbox::WwwAttach; # internal package
use strict;
use warnings;
use bytes (); # only for bytes::length
use Email::MIME::ContentType qw(parse_content_type);
use PublicInbox::MIME;
use PublicInbox::MsgIter;

sub get_attach_i { # msg_iter callback
	my ($part, $depth, @idx) = @{$_[0]};
	my $res = $_[1];
	return if join('.', @idx) ne $res->[3]; # $idx
	$res->[0] = 200;
	my $ct = $part->content_type;
	$ct = parse_content_type($ct) if $ct;

	# discrete == type, we remain Debian wheezy-compatible
	if ($ct && (($ct->{discrete} || '') eq 'text')) {
		# display all text as text/plain:
		my $cset = $ct->{attributes}->{charset};
		if ($cset && ($cset =~ /\A[a-zA-Z0-9_\-]+\z/)) {
			$res->[1]->[1] .= qq(; charset=$cset);
		}
	} else { # TODO: allow user to configure safe types
		$res->[1]->[1] = 'application/octet-stream';
	}
	$part = $part->body;
	push @{$res->[1]}, 'Content-Length', bytes::length($part);
	$res->[2]->[0] = $part;
}

# /$LISTNAME/$MESSAGE_ID/$IDX-$FILENAME
sub get_attach ($$$) {
	my ($ctx, $idx, $fn) = @_;
	my $res = [ 404, [ 'Content-Type', 'text/plain' ], [ "Not found\n" ] ];
	my $mime = $ctx->{-inbox}->msg_by_mid($ctx->{mid}) or return $res;
	$mime = PublicInbox::MIME->new($mime);
	$res->[3] = $idx;
	msg_iter($mime, \&get_attach_i, $res);
	pop @$res; # cleanup before letting PSGI server see it
	$res
}

1;
