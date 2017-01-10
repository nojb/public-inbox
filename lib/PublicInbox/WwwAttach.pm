# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# For retrieving attachments from messages in the WWW interface
package PublicInbox::WwwAttach; # internal package
use strict;
use warnings;
use PublicInbox::MIME;
use Email::MIME::ContentType qw(parse_content_type);
$Email::MIME::ContentType::STRICT_PARAMS = 0;
use PublicInbox::MsgIter;

# /$LISTNAME/$MESSAGE_ID/$IDX-$FILENAME
sub get_attach ($$$) {
	my ($ctx, $idx, $fn) = @_;
	my $res = [ 404, [ 'Content-Type', 'text/plain' ], [ "Not found\n" ] ];
	my $mime = $ctx->{-inbox}->msg_by_mid($ctx->{mid}) or return $res;
	$mime = PublicInbox::MIME->new($mime);
	msg_iter($mime, sub {
		my ($part, $depth, @idx) = @{$_[0]};
		return if join('.', @idx) ne $idx;
		$res->[0] = 200;
		my $ct = $part->content_type;
		$ct = parse_content_type($ct) if $ct;

		# discrete == type, we remain Debian wheezy-compatible
		if ($ct && (($ct->{discrete} || '') eq 'text')) {
			# display all text as text/plain:
			my $cset = $ct->{attributes}->{charset};
			if ($cset && ($cset =~ /\A[\w-]+\z/)) {
				$res->[1]->[1] .= qq(; charset=$cset);
			}
		} else { # TODO: allow user to configure safe types
			$res->[1]->[1] = 'application/octet-stream';
		}
		$part = $part->body;
		push @{$res->[1]}, 'Content-Length', bytes::length($part);
		$res->[2]->[0] = $part;
	});
	$res;
}

1;
