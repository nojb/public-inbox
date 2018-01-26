# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Atom body stream for which yields getline+close methods
package PublicInbox::WwwAtomStream;
use strict;
use warnings;

use POSIX qw(strftime);
use Date::Parse qw(str2time);
use Digest::SHA qw(sha1_hex);
use PublicInbox::Address;
use PublicInbox::Hval qw(ascii_html);
use PublicInbox::MID qw/mid_clean mid_escape/;

# called by PSGI server after getline:
sub close {}

sub new {
	my ($class, $ctx, $cb) = @_;
	$ctx->{emit_header} = 1;
	$ctx->{feed_base_url} = $ctx->{-inbox}->base_url($ctx->{env});
	bless { cb => $cb || *close, ctx => $ctx }, $class;
}

sub response {
	my ($class, $ctx, $code, $cb) = @_;
	[ $code, [ 'Content-Type', 'application/atom+xml' ],
	  $class->new($ctx, $cb) ]
}

# called once for each message by PSGI server
sub getline {
	my ($self) = @_;
	if (my $middle = $self->{cb}) {
		my $mime = $middle->();
		return feed_entry($self, $mime) if $mime;
	}
	delete $self->{cb} ? '</feed>' : undef;
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

sub atom_header {
	my ($ctx, $title) = @_;
	my $ibx = $ctx->{-inbox};
	my $base_url = $ctx->{feed_base_url};
	my $search_q = $ctx->{search_query};
	my $self_url = $base_url;
	my $mid = $ctx->{mid};
	if (defined $mid) { # per-thread
		$self_url .= mid_escape($mid).'/t.atom';
	} elsif (defined $search_q) {
		my $query = $search_q->{'q'};
		$title = title_tag("$query - search results");
		$base_url .= '?' . $search_q->qs_html(x => undef);
		$self_url .= '?' . $search_q->qs_html;
	} else {
		$title = title_tag($ibx->description);
		$self_url .= 'new.atom';
	}
	my $mtime = (stat($ibx->{mainrepo}))[9] || time;

	qq(<?xml version="1.0" encoding="us-ascii"?>\n) .
	qq(<feed\nxmlns="http://www.w3.org/2005/Atom"\n) .
	qq(xmlns:thr="http://purl.org/syndication/thread/1.0">) .
	qq{$title} .
	qq(<link\nrel="alternate"\ntype="text/html") .
		qq(\nhref="$base_url"/>) .
	qq(<link\nrel="self"\nhref="$self_url"/>) .
	qq(<id>mailto:$ibx->{-primary_address}</id>) .
	feed_updated(gmtime($mtime));
}

sub mid2uuid ($) {
	my ($mid) = @_;
	utf8::encode($mid); # really screwed up In-Reply-To fields exist
	$mid = sha1_hex($mid);
	my $h = '[a-f0-9]';
	my (@uuid5) = ($mid =~ m!\A($h{8})($h{4})($h{4})($h{4})($h{12})!o);
	'urn:uuid:' . join('-', @uuid5);
}

# returns undef or string
sub feed_entry {
	my ($self, $mime) = @_;
	my $ctx = $self->{ctx};
	my $hdr = $mime->header_obj;
	my $mid = mid_clean($hdr->header_raw('Message-ID'));
	my $irt = PublicInbox::View::in_reply_to($hdr);
	my $uuid = mid2uuid($mid);
	my $base = $ctx->{feed_base_url};
	if (defined $irt) {
		my $irt_uuid = mid2uuid($irt);
		$irt = mid_escape($irt);
		$irt = qq(<thr:in-reply-to\nref="$irt_uuid"\n).
			qq(href="$base$irt/"/>);
	} else {
		$irt = '';
	}
	my $href = $base . mid_escape($mid) . '/';
	my $date = $hdr->header('Date');
	my $t = eval { str2time($date) } if defined $date;
	my @t = gmtime(defined $t ? $t : time);
	my $updated = feed_updated(@t);

	my $title = $hdr->header('Subject');
	$title = '(no subject)' unless defined $title && $title ne '';
	$title = title_tag($title);

	my $from = $hdr->header('From') or return;
	my ($email) = PublicInbox::Address::emails($from);
	my $name = join(', ',PublicInbox::Address::names($from));
	$name = ascii_html($name);
	$email = ascii_html($email);

	my $s = '';
	if (delete $ctx->{emit_header}) {
		$s .= atom_header($ctx, $title);
	}
	$s .= "<entry><author><name>$name</name><email>$email</email>" .
		"</author>$title$updated" .
		qq(<link\nhref="$href"/>).
		"<id>$uuid</id>$irt" .
		qq{<content\ntype="xhtml">} .
		qq{<div\nxmlns="http://www.w3.org/1999/xhtml">} .
		qq(<pre\nstyle="white-space:pre-wrap">) .
		PublicInbox::View::multipart_text_as_html($mime, $href) .
		'</pre></div></content></entry>';
}

sub feed_updated {
	'<updated>' . strftime('%Y-%m-%dT%H:%M:%SZ', @_) . '</updated>';
}

1;
