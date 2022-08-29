# Copyright (C) 2016-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Atom body stream for HTTP responses
# See PublicInbox::GzipFilter for details.
package PublicInbox::WwwAtomStream;
use strict;
use parent 'PublicInbox::GzipFilter';

use POSIX qw(strftime);
use Digest::SHA qw(sha1_hex);
use PublicInbox::Address;
use PublicInbox::Hval qw(ascii_html mid_href);
use PublicInbox::MsgTime qw(msg_timestamp);

sub new {
	my ($class, $ctx, $cb) = @_;
	$ctx->{feed_base_url} = $ctx->{ibx}->base_url($ctx->{env});
	$ctx->{cb} = $cb || \&PublicInbox::GzipFilter::close;
	$ctx->{emit_header} = 1;
	bless $ctx, $class;
}

sub async_next ($) {
	my ($http) = @_; # PublicInbox::HTTP
	my $ctx = $http->{forward} or return;
	eval {
		if (my $smsg = $ctx->{smsg} = $ctx->{cb}->($ctx)) {
			$ctx->smsg_blob($smsg);
		} else {
			$ctx->write('</feed>');
			$ctx->close;
		}
	};
	warn "E: $@" if $@;
}

sub async_eml { # for async_blob_cb
	my ($ctx, $eml) = @_;
	my $smsg = delete $ctx->{smsg};
	$smsg->{mid} // $smsg->populate($eml);
	$ctx->write(feed_entry($ctx, $smsg, $eml));
}

sub response {
	my ($class, $ctx, $code, $cb) = @_;
	my $res_hdr = [ 'Content-Type' => 'application/atom+xml' ];
	$class->new($ctx, $cb);
	$ctx->psgi_response($code, $res_hdr);
}

# called once for each message by PSGI server
sub getline {
	my ($self) = @_;
	my $cb = $self->{cb} or return;
	while (my $smsg = $cb->($self)) {
		my $eml = $self->{ibx}->smsg_eml($smsg) or next;
		return $self->translate(feed_entry($self, $smsg, $eml));
	}
	delete $self->{cb};
	$self->zflush('</feed>');
}

# private

sub title_tag {
	my ($title) = @_;
	$title =~ tr/\t\n / /s; # squeeze spaces
	# try to avoid the type attribute in title:
	$title = ascii_html($title);
	my $type = index($title, '&') >= 0 ? "\ntype=\"html\"" : '';
	"<title$type>$title</title>";
}

sub to_uuid ($) {
	my ($any) = @_;
	utf8::encode($any); # really screwed up In-Reply-To fields exist
	$any = sha1_hex($any);
	my $h = '[a-f0-9]';
	my (@uuid5) = ($any =~ m!\A($h{8})($h{4})($h{4})($h{4})($h{12})!o);
	'urn:uuid:' . join('-', @uuid5);
}

sub atom_header {
	my ($ctx, $title) = @_;
	my $ibx = $ctx->{ibx};
	my $base_url = $ctx->{feed_base_url};
	my $search_q = $ctx->{search_query};
	my $self_url = $base_url;
	my $mid = $ctx->{mid};
	my $page_id;
	if (defined $mid) { # per-thread
		$self_url .= mid_href($mid).'/t.atom';
		$page_id = to_uuid("t\n".$mid)
	} elsif (defined $search_q) {
		my $query = $search_q->{'q'};
		$title = title_tag("$query - search results");
		$base_url .= '?' . $search_q->qs_html(x => undef);
		$self_url .= '?' . $search_q->qs_html;
		$page_id = to_uuid("q\n".$query);
	} else {
		$title = title_tag($ibx->description);
		$self_url .= 'new.atom';
		if (defined(my $addr = $ibx->{-primary_address})) {
			$page_id = "mailto:$addr";
		} else {
			$page_id = to_uuid($self_url);
		}
	}
	qq(<?xml version="1.0" encoding="us-ascii"?>\n) .
	qq(<feed\nxmlns="http://www.w3.org/2005/Atom"\n) .
	qq(xmlns:thr="http://purl.org/syndication/thread/1.0">) .
	qq{$title} .
	qq(<link\nrel="alternate"\ntype="text/html") .
		qq(\nhref="$base_url"/>) .
	qq(<link\nrel="self"\nhref="$self_url"/>) .
	qq(<id>$page_id</id>) .
	feed_updated($ibx->modified);
}

# returns undef or string
sub feed_entry {
	my ($ctx, $smsg, $eml) = @_;
	my $mid = $smsg->{mid};
	my $irt = PublicInbox::View::in_reply_to($eml);
	my $uuid = to_uuid($mid);
	my $base = $ctx->{feed_base_url};
	if (defined $irt) {
		my $irt_uuid = to_uuid($irt);
		$irt = mid_href($irt);
		$irt = qq(<thr:in-reply-to\nref="$irt_uuid"\n).
			qq(href="$base$irt/"/>);
	} else {
		$irt = '';
	}
	my $href = $base . mid_href($mid) . '/';
	my $updated = feed_updated(msg_timestamp($eml));

	my $title = $eml->header('Subject');
	$title = '(no subject)' unless defined $title && $title ne '';
	$title = title_tag($title);

	my $from = $eml->header('From') // $eml->header('Sender') //
		$ctx->{ibx}->{-primary_address};
	my ($email) = PublicInbox::Address::emails($from);
	my $name = ascii_html(join(', ', PublicInbox::Address::names($from)));
	$email = ascii_html($email // $ctx->{ibx}->{-primary_address});

	my $s = delete($ctx->{emit_header}) ? atom_header($ctx, $title) : '';
	$s .= "<entry><author><name>$name</name><email>$email</email>" .
		"</author>$title$updated" .
		qq(<link\nhref="$href"/>).
		"<id>$uuid</id>$irt" .
		qq{<content\ntype="xhtml">} .
		qq{<div\nxmlns="http://www.w3.org/1999/xhtml">} .
		qq(<pre\nstyle="white-space:pre-wrap">);
	$ctx->{obuf} = \$s;
	$ctx->{mhref} = $href;
	$ctx->{changed_href} = "${href}#related";
	PublicInbox::View::multipart_text_as_html($eml, $ctx);
	delete $ctx->{obuf};
	$s .= '</pre></div></content></entry>';
}

sub feed_updated {
	my ($t) = @_;
	'<updated>' . strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($t)) . '</updated>';
}

1;
