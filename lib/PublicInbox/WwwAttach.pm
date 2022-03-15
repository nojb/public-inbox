# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# For retrieving attachments from messages in the WWW interface
package PublicInbox::WwwAttach; # internal package
use strict;
use v5.10.1;
use parent qw(PublicInbox::GzipFilter);
use PublicInbox::Eml;

sub referer_match ($) {
	my ($ctx) = @_;
	my $env = $ctx->{env};
	return 1 if $env->{REQUEST_METHOD} eq 'POST';
	my $referer = lc($env->{HTTP_REFERER} // '');
	return 1 if $referer eq ''; # no referer is always OK for wget/curl

	# prevent deep-linking from other domains on some browsers (Firefox)
	# n.b.: $ctx->{ibx}->base_url($env) with INBOX_URL won't work
	# with dillo, we can only match "$url_scheme://$HTTP_HOST/" without
	# path components
	my $base_url = lc($env->{'psgi.url_scheme'} . '://' .
			($env->{HTTP_HOST} //
			 "$env->{SERVER_NAME}:$env->{SERVER_PORT}") . '/');
	index($referer, $base_url) == 0;
}

sub get_attach_i { # ->each_part callback
	my ($part, $depth, $idx) = @{$_[0]};
	my $ctx = $_[1];
	return if $idx ne $ctx->{idx}; # [0-9]+(?:\.[0-9]+)+
	my $res = $ctx->{res};
	$res->[0] = 200;
	my $ct = $part->ct;
	if ($ct && (($ct->{type} || '') eq 'text')) {
		# display all text as text/plain:
		my $cset = $ct->{attributes}->{charset};
		if ($cset && ($cset =~ /\A[a-zA-Z0-9_\-]+\z/)) {
			$res->[1]->[1] .= qq(; charset=$cset);
		}
		$ctx->{gz} = PublicInbox::GzipFilter::gz_or_noop($res->[1],
								$ctx->{env});
		$part = $ctx->zflush($part->body);
	} else { # TODO: allow user to configure safe types
		if (referer_match($ctx)) {
			$res->[1]->[1] = 'application/octet-stream';
			$part = $part->body;
		} else {
			$res->[0] = 403;
			$res->[1]->[1] = 'text/html';
			$part = <<"";
<html><head><title>download
attachment</title><body><pre>Deep-linking prevented</pre><form
method=post\naction=""><input type=submit value="Download attachment"
/></form></body></html>

		}
	}
	push @{$res->[1]}, 'Content-Length', length($part);
	$res->[2]->[0] = $part;
}

sub async_eml { # for async_blob_cb
	my ($ctx, $eml) = @_;
	eval { $eml->each_part(\&get_attach_i, $ctx, 1) };
	if ($@) {
		$ctx->{res}->[0] = 500;
		warn "E: $@";
	}
}

sub async_next {
	my ($http) = @_;
	my $ctx = $http->{forward} or return; # client aborted
	# finally, we call the user-supplied callback
	eval { $ctx->{wcb}->($ctx->{res}) };
	warn "E: $@" if $@;
}

sub scan_attach ($) { # public-inbox-httpd only
	my ($ctx) = @_;
	$ctx->{env}->{'psgix.io'}->{forward} = $ctx;
	$ctx->smsg_blob($ctx->{smsg});
}

# /$LISTNAME/$MESSAGE_ID/$IDX-$FILENAME
sub get_attach ($$$) {
	my ($ctx, $idx, $fn) = @_;
	$ctx->{res} = [ 404, [ 'Content-Type' => 'text/plain' ],
				[ "Not found\n" ] ];
	$ctx->{idx} = $idx;
	bless $ctx, __PACKAGE__;
	my $eml;
	if ($ctx->{smsg} = $ctx->{ibx}->smsg_by_mid($ctx->{mid})) {
		return sub { # public-inbox-httpd-only
			$ctx->{wcb} = $_[0];
			scan_attach($ctx);
		} if $ctx->{env}->{'pi-httpd.async'};
		# generic PSGI:
		$eml = $ctx->{ibx}->smsg_eml($ctx->{smsg});
	} elsif (!$ctx->{ibx}->over) {
		if (my $bref = $ctx->{ibx}->msg_by_mid($ctx->{mid})) {
			$eml = PublicInbox::Eml->new($bref);
		}
	}
	$eml->each_part(\&get_attach_i, $ctx, 1) if $eml;
	$ctx->{res}
}

1;
