# Copyright (C) 2014-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Main web interface for mailing list archives
#
# We focus on the lowest common denominators here:
# - targeted at text-only console browsers (w3m, links, etc..)
# - Only basic HTML, CSS only for line-wrapping <pre> text content for GUIs
#   and diff/syntax-highlighting (optional)
# - No JavaScript, graphics or icons allowed.
# - Must not rely on static content
# - UTF-8 is only for user-content, 7-bit US-ASCII for us
package PublicInbox::WWW;
use 5.008;
use strict;
use warnings;
use PublicInbox::Config;
use PublicInbox::Hval;
use URI::Escape qw(uri_unescape);
use PublicInbox::MID qw(mid_escape);
require PublicInbox::Git;
use PublicInbox::GitHTTPBackend;

# TODO: consider a routing tree now that we have more endpoints:
our $INBOX_RE = qr!\A/([\w\-][\w\.\-]*)!;
our $MID_RE = qr!([^/]+)!;
our $END_RE = qr!(T/|t/|t\.mbox(?:\.gz)?|t\.atom|raw|)!;
our $ATTACH_RE = qr!(\d[\.\d]*)-([[:alnum:]][\w\.-]+[[:alnum:]])!i;
our $OID_RE = qr![a-f0-9]{7,40}!;

sub new {
	my ($class, $pi_config) = @_;
	$pi_config ||= PublicInbox::Config->new;
	bless { pi_config => $pi_config }, $class;
}

# backwards compatibility, do not use
sub run {
	my ($req, $method) = @_;
	PublicInbox::WWW->new->call($req->env);
}

my %path_re_cache;

sub path_re ($) {
	my $sn = $_[0]->{SCRIPT_NAME};
	$path_re_cache{$sn} ||= do {
		$sn = '/'.$sn unless index($sn, '/') == 0;
		$sn =~ s!/\z!!;
		qr!\A(?:https?://[^/]+)?\Q$sn\E(/[^\?\#]+)!;
	};
}

sub call {
	my ($self, $env) = @_;
	my $ctx = { env => $env, www => $self };

	# we don't care about multi-value
	my %qp = map {
		utf8::decode($_);
		my ($k, $v) = split('=', uri_unescape($_), 2);
		$v = '' unless defined $v;
		$v =~ tr/+/ /;
		($k, $v)
	} split(/[&;]+/, $env->{QUERY_STRING});
	$ctx->{qp} = \%qp;

	# not using $env->{PATH_INFO} here since that's already decoded
	my ($path_info) = ($env->{REQUEST_URI} =~ path_re($env));
	my $method = $env->{REQUEST_METHOD};

	if ($method eq 'POST') {
		if ($path_info =~ m!$INBOX_RE/(?:(\d+)/)?(git-upload-pack)\z!) {
			my ($part, $path) = ($2, $3);
			return invalid_inbox($ctx, $1) ||
				serve_git($ctx, $part, $path);
		} elsif ($path_info =~ m!$INBOX_RE/!o) {
			return invalid_inbox($ctx, $1) || mbox_results($ctx);
		}
	}
	elsif ($method !~ /\AGET|HEAD\z/) {
		return r(405, 'Method Not Allowed');
	}

	# top-level indices and feeds
	if ($path_info eq '/') {
		r404();
	} elsif ($path_info =~ m!$INBOX_RE\z!o) {
		invalid_inbox($ctx, $1) || r301($ctx, $1);
	} elsif ($path_info =~ m!$INBOX_RE(?:/|/index\.html)?\z!o) {
		invalid_inbox($ctx, $1) || get_index($ctx);
	} elsif ($path_info =~ m!$INBOX_RE/(?:atom\.xml|new\.atom)\z!o) {
		invalid_inbox($ctx, $1) || get_atom($ctx);
	} elsif ($path_info =~ m!$INBOX_RE/new\.html\z!o) {
		invalid_inbox($ctx, $1) || get_new($ctx);
	} elsif ($path_info =~ m!$INBOX_RE/(?:(\d+)/)?
				($PublicInbox::GitHTTPBackend::ANY)\z!ox) {
		my ($part, $path) = ($2, $3);
		invalid_inbox($ctx, $1) || serve_git($ctx, $part, $path);
	} elsif ($path_info =~ m!$INBOX_RE/([\w-]+).mbox\.gz\z!o) {
		serve_mbox_range($ctx, $1, $2);
	} elsif ($path_info =~ m!$INBOX_RE/$MID_RE/$END_RE\z!o) {
		msg_page($ctx, $1, $2, $3);

	} elsif ($path_info =~ m!$INBOX_RE/$MID_RE/$ATTACH_RE\z!o) {
		my ($idx, $fn) = ($3, $4);
		invalid_inbox_mid($ctx, $1, $2) || get_attach($ctx, $idx, $fn);
	# in case people leave off the trailing slash:
	} elsif ($path_info =~ m!$INBOX_RE/$MID_RE/(T|t)\z!o) {
		my ($inbox, $mid_ue, $suffix) = ($1, $2, $3);
		$suffix .= $suffix =~ /\A[tT]\z/ ? '/#u' : '/';
		r301($ctx, $inbox, $mid_ue, $suffix);

	} elsif ($path_info =~ m!$INBOX_RE/$MID_RE/R/?\z!o) {
		my ($inbox, $mid_ue) = ($1, $2);
		r301($ctx, $inbox, $mid_ue, '#R');

	} elsif ($path_info =~ m!$INBOX_RE/$MID_RE/f/?\z!o) {
		r301($ctx, $1, $2);
	} elsif ($path_info =~ m!$INBOX_RE/_/text(?:/(.*))?\z!o) {
		get_text($ctx, $1, $2);
	} elsif ($path_info =~ m!$INBOX_RE/([\w\-\.]+)\.css\z!o) {
		get_css($self, $2);
	} elsif ($path_info =~ m!$INBOX_RE/($OID_RE)/s/\z!o) {
		get_vcs_object($ctx, $1, $2);
	} elsif ($path_info =~ m!$INBOX_RE/($OID_RE)/s/([\w\.\-]+)\z!o) {
		get_vcs_object($ctx, $1, $2, $3);
	} elsif ($path_info =~ m!$INBOX_RE/($OID_RE)/s\z!o) {
		r301($ctx, $1, $2, 's/');
	# convenience redirects order matters
	} elsif ($path_info =~ m!$INBOX_RE/([^/]{2,})\z!o) {
		r301($ctx, $1, $2);

	} else {
		legacy_redirects($ctx, $path_info);
	}
}

# for CoW-friendliness, MOOOOO!
sub preload {
	my ($self) = @_;
	require PublicInbox::Feed;
	require PublicInbox::View;
	require PublicInbox::SearchThread;
	require PublicInbox::MIME;
	require Digest::SHA;
	require POSIX;

	foreach (qw(PublicInbox::Search PublicInbox::SearchView
			PublicInbox::Mbox IO::Compress::Gzip
			PublicInbox::NewsWWW)) {
		eval "require $_;";
	}
	if (ref($self)) {
		$self->stylesheets_prepare($_) for ('', '../', '../../');
	}
}

# private functions below

sub r404 {
	my ($ctx) = @_;
	if ($ctx && $ctx->{mid}) {
		require PublicInbox::ExtMsg;
		searcher($ctx);
		return PublicInbox::ExtMsg::ext_msg($ctx);
	}
	r(404, 'Not Found');
}

# simple response for errors
sub r { [ $_[0], ['Content-Type' => 'text/plain'], [ join(' ', @_, "\n") ] ] }

# returns undef if valid, array ref response if invalid
sub invalid_inbox ($$) {
	my ($ctx, $inbox) = @_;
	my $www = $ctx->{www};
	my $obj = $www->{pi_config}->lookup_name($inbox);
	if (defined $obj) {
		$ctx->{git} = $obj->git;
		$ctx->{-inbox} = $obj;
		return;
	}

	# sometimes linkifiers (not ours!) screw up automatic link
	# generation and link things intended for nntp:// to https?://,
	# so try to infer links and redirect them to the appropriate
	# list URL.
	$www->news_www->call($ctx->{env});
}

# returns undef if valid, array ref response if invalid
sub invalid_inbox_mid {
	my ($ctx, $inbox, $mid_ue) = @_;
	my $ret = invalid_inbox($ctx, $inbox);
	return $ret if $ret;

	my $mid = $ctx->{mid} = uri_unescape($mid_ue);
	my $ibx = $ctx->{-inbox};
	if ($mid =~ m!\A([a-f0-9]{2})([a-f0-9]{38})\z!) {
		my ($x2, $x38) = ($1, $2);
		# this is horrifically wasteful for legacy URLs:
		my $str = $ctx->{-inbox}->msg_by_path("$x2/$x38") or return;
		require Email::Simple;
		my $s = Email::Simple->new($str);
		$mid = PublicInbox::MID::mid_clean($s->header('Message-ID'));
		return r301($ctx, $inbox, mid_escape($mid));
	}
	undef;
}

# /$INBOX/new.atom                     -> Atom feed, includes replies
sub get_atom {
	my ($ctx) = @_;
	require PublicInbox::Feed;
	PublicInbox::Feed::generate($ctx);
}

# /$INBOX/new.html			-> HTML only
sub get_new {
	my ($ctx) = @_;
	require PublicInbox::Feed;
	PublicInbox::Feed::new_html($ctx);
}

# /$INBOX/?r=$GIT_COMMIT                 -> HTML only
sub get_index {
	my ($ctx) = @_;
	require PublicInbox::Feed;
	searcher($ctx);
	if ($ctx->{env}->{QUERY_STRING} =~ /(?:\A|[&;])q=/) {
		require PublicInbox::SearchView;
		PublicInbox::SearchView::sres_top_html($ctx);
	} else {
		PublicInbox::Feed::generate_html_index($ctx);
	}
}

# /$INBOX/$MESSAGE_ID/raw                    -> raw mbox
sub get_mid_txt {
	my ($ctx) = @_;
	require PublicInbox::Mbox;
	PublicInbox::Mbox::emit_raw($ctx) || r404($ctx);
}

# /$INBOX/$MESSAGE_ID/                   -> HTML content (short quotes)
sub get_mid_html {
	my ($ctx) = @_;
	require PublicInbox::View;
	searcher($ctx);
	PublicInbox::View::msg_page($ctx) || r404($ctx);
}

# /$INBOX/$MESSAGE_ID/t/
sub get_thread {
	my ($ctx, $flat) = @_;
	searcher($ctx) or return need_search($ctx);
	$ctx->{flat} = $flat;
	require PublicInbox::View;
	PublicInbox::View::thread_html($ctx);
}

# /$INBOX/_/text/$KEY/
# /$INBOX/_/text/$KEY/raw
# KEY may contain slashes
sub get_text {
	my ($ctx, $inbox, $key) = @_;
	my $r404 = invalid_inbox($ctx, $inbox);
	return $r404 if $r404;

	require PublicInbox::WwwText;
	PublicInbox::WwwText::get_text($ctx, $key);
}

# show git objects (blobs and commits)
# /$INBOX/_/$OBJECT_ID/show
# /$INBOX/_/${OBJECT_ID}_${FILENAME}
# KEY may contain slashes
sub get_vcs_object ($$$;$) {
	my ($ctx, $inbox, $oid, $filename) = @_;
	my $r404 = invalid_inbox($ctx, $inbox);
	return $r404 if $r404;
	require PublicInbox::ViewVCS;
	PublicInbox::ViewVCS::show($ctx, $oid, $filename);
}

sub ctx_get {
	my ($ctx, $key) = @_;
	my $val = $ctx->{$key};
	(defined $val && $val ne '') or die "BUG: bad ctx, $key unusable";
	$val;
}

# search support is optional, returns undef if Xapian is not installed
# or not configured for the given GIT_DIR
sub searcher {
	my ($ctx) = @_;
	eval {
		require PublicInbox::Search;
		$ctx->{srch} = $ctx->{-inbox}->search;
	};
}

sub need_search {
	my ($ctx) = @_;
	my $msg = <<EOF;
<html><head><title>Search not available for this
public-inbox</title><body><pre>Search is not available for this public-inbox
<a href="../">Return to index</a></pre></body></html>
EOF
	[ 501, [ 'Content-Type' => 'text/html; charset=UTF-8' ], [ $msg ] ];
}

# /$INBOX/$MESSAGE_ID/t.mbox           -> thread as mbox
# /$INBOX/$MESSAGE_ID/t.mbox.gz        -> thread as gzipped mbox
# note: I'm not a big fan of other compression formats since they're
# significantly more expensive on CPU than gzip and less-widely available,
# especially on older systems.  Stick to zlib since that's what git uses.
sub get_thread_mbox {
	my ($ctx, $sfx) = @_;
	my $srch = searcher($ctx) or return need_search($ctx);
	require PublicInbox::Mbox;
	PublicInbox::Mbox::thread_mbox($ctx, $srch, $sfx);
}


# /$INBOX/$MESSAGE_ID/t.atom		  -> thread as Atom feed
sub get_thread_atom {
	my ($ctx) = @_;
	searcher($ctx) or return need_search($ctx);
	require PublicInbox::Feed;
	PublicInbox::Feed::generate_thread_atom($ctx);
}

sub legacy_redirects {
	my ($ctx, $path_info) = @_;

	# single-message pages
	if ($path_info =~ m!$INBOX_RE/m/(\S+)/\z!o) {
		r301($ctx, $1, $2);
	} elsif ($path_info =~ m!$INBOX_RE/m/(\S+)/raw\z!o) {
		r301($ctx, $1, $2, 'raw');

	} elsif ($path_info =~ m!$INBOX_RE/f/(\S+)/\z!o) {
		r301($ctx, $1, $2);

	# thread display
	} elsif ($path_info =~ m!$INBOX_RE/t/(\S+)/\z!o) {
		r301($ctx, $1, $2, 't/#u');

	} elsif ($path_info =~ m!$INBOX_RE/t/(\S+)/mbox(\.gz)?\z!o) {
		r301($ctx, $1, $2, "t.mbox$3");

	# even older legacy redirects
	} elsif ($path_info =~ m!$INBOX_RE/m/(\S+)\.html\z!o) {
		r301($ctx, $1, $2);

	} elsif ($path_info =~ m!$INBOX_RE/t/(\S+)\.html\z!o) {
		r301($ctx, $1, $2, 't/#u');

	} elsif ($path_info =~ m!$INBOX_RE/f/(\S+)\.html\z!o) {
		r301($ctx, $1, $2);

	} elsif ($path_info =~ m!$INBOX_RE/(?:m|f)/(\S+)\.txt\z!o) {
		r301($ctx, $1, $2, 'raw');

	} elsif ($path_info =~ m!$INBOX_RE/t/(\S+)(\.mbox(?:\.gz)?)\z!o) {
		r301($ctx, $1, $2, "t$3");

	# legacy convenience redirects, order still matters
	} elsif ($path_info =~ m!$INBOX_RE/m/(\S+)\z!o) {
		r301($ctx, $1, $2);
	} elsif ($path_info =~ m!$INBOX_RE/t/(\S+)\z!o) {
		r301($ctx, $1, $2, 't/#u');
	} elsif ($path_info =~ m!$INBOX_RE/f/(\S+)\z!o) {
		r301($ctx, $1, $2);

	# some Message-IDs have slashes in them and the HTTP server
	# may try to be clever and unescape them :<
	} elsif ($path_info =~ m!$INBOX_RE/(\S+/\S+)/$END_RE\z!o) {
		msg_page($ctx, $1, $2, $3);

	# in case people leave off the trailing slash:
	} elsif ($path_info =~ m!$INBOX_RE/(\S+/\S+)/(T|t)\z!o) {
		r301($ctx, $1, $2, $3 eq 't' ? 't/#u' : $3);
	} elsif ($path_info =~ m!$INBOX_RE/(\S+/\S+)/f\z!o) {
		r301($ctx, $1, $2);
	} else {
		$ctx->{www}->news_www->call($ctx->{env});
	}
}

sub r301 {
	my ($ctx, $inbox, $mid_ue, $suffix) = @_;
	my $obj = $ctx->{-inbox};
	unless ($obj) {
		my $r404 = invalid_inbox($ctx, $inbox);
		return $r404 if $r404;
		$obj = $ctx->{-inbox};
	}
	my $url = $obj->base_url($ctx->{env});
	my $qs = $ctx->{env}->{QUERY_STRING};
	if (defined $mid_ue) {
		# common, and much nicer as '@' than '%40':
		$mid_ue =~ s/%40/@/g;
		$url .= $mid_ue . '/';
	}
	$url .= $suffix if (defined $suffix);
	$url .= "?$qs" if $qs ne '';

	[ 301,
	  [ Location => $url, 'Content-Type' => 'text/plain' ],
	  [ "Redirecting to $url\n" ] ]
}

sub msg_page {
	my ($ctx, $inbox, $mid_ue, $e) = @_;
	my $ret;
	$ret = invalid_inbox_mid($ctx, $inbox, $mid_ue) and return $ret;
	'' eq $e and return get_mid_html($ctx);
	'T/' eq $e and return get_thread($ctx, 1);
	't/' eq $e and return get_thread($ctx);
	't.atom' eq $e and return get_thread_atom($ctx);
	't.mbox' eq $e and return get_thread_mbox($ctx);
	't.mbox.gz' eq $e and return get_thread_mbox($ctx, '.gz');
	'raw' eq $e and return get_mid_txt($ctx);

	# legacy, but no redirect for compatibility:
	'f/' eq $e and return get_mid_html($ctx);
	r404($ctx);
}

sub serve_git {
	my ($ctx, $part, $path) = @_;
	my $env = $ctx->{env};
	my $ibx = $ctx->{-inbox};
	my $git = defined $part ? $ibx->git_part($part) : $ibx->git;
	$git ? PublicInbox::GitHTTPBackend::serve($env, $git, $path) : r404();
}

sub mbox_results {
	my ($ctx) = @_;
	if ($ctx->{env}->{QUERY_STRING} =~ /(?:\A|[&;])q=/) {
		searcher($ctx) or return need_search($ctx);
		require PublicInbox::SearchView;
		return PublicInbox::SearchView::mbox_results($ctx);
	}
	r404();
}

sub serve_mbox_range {
	my ($ctx, $inbox, $range) = @_;
	invalid_inbox($ctx, $inbox) || eval {
		require PublicInbox::Mbox;
		searcher($ctx);
		PublicInbox::Mbox::emit_range($ctx, $range);
	}
}

sub news_www {
	my ($self) = @_;
	$self->{news_www} ||= do {
		require PublicInbox::NewsWWW;
		PublicInbox::NewsWWW->new($self->{pi_config});
	}
}

sub get_attach {
	my ($ctx, $idx, $fn) = @_;
	require PublicInbox::WwwAttach;
	PublicInbox::WwwAttach::get_attach($ctx, $idx, $fn);
}

# User-generated content (UGC) may have excessively long lines
# and screw up rendering on some browsers, so we use pre-wrap.
#
# We also force everything to the same scaled font-size because GUI
# browsers (tested both Firefox and surf (webkit)) uses a larger font
# for the Search <form> element than the rest of the page.  Font size
# uniformity is important to people who rely on gigantic fonts.
# Finally, we use monospace to ensure the Search field and button
# has the same size and spacing as everything else which is
# <pre>-formatted anyways.
our $STYLE = 'pre{white-space:pre-wrap}*{font-size:100%;font-family:monospace}';

sub stylesheets_prepare ($$) {
	my ($self, $upfx) = @_;
	my $mini = eval {
		require CSS::Minifier;
		sub { CSS::Minifier::minify(input => $_[0]) };
	} || eval {
		require CSS::Minifier::XS;
		sub { CSS::Minifier::XS::minify($_[0]) };
	} || sub { $_[0] };

	my $css_map = {};
	my $stylesheets = $self->{pi_config}->{css} || [];
	my $links = [];
	my $inline_ok = 1;

	foreach my $s (@$stylesheets) {
		my $attr = {};
		local $_ = $s;
		foreach my $k (qw(media title href)) {
			if (s/\s*$k='([^']+)'// || s/\s*$k=(\S+)//) {
				$attr->{$k} = $1;
			}
		}

		if (defined $attr->{href}) {
			$inline_ok = 0;
		} else {
			open(my $fh, '<', $_) or do {
				warn "failed to open $_: $!\n";
				next;
			};
			my ($key) = (m!([^/]+?)(?:\.css)?\z!i);
			my $ctime = 0;
			my $local = do { local $/; <$fh> };
			if ($local =~ /\S/) {
				$ctime = sprintf('%x',(stat($fh))[10]);
				$local = $mini->($local);
			}
			$css_map->{$key} = $local;
			$attr->{href} = "$upfx$key.css?$ctime";
			if (defined($attr->{title})) {
				$inline_ok = 0;
			} elsif (($attr->{media}||'screen') eq 'screen') {
				$attr->{-inline} = $local;
			}
		}
		push @$links, $attr;
	}

	my $buf = "<style>$STYLE";
	if ($inline_ok) {
		my @ext; # for media=print and whatnot
		foreach my $attr (@$links) {
			if (defined(my $str = delete $attr->{-inline})) {
				$buf .= $str;
			} else {
				push @ext, $attr;
			}
		}
		$links = \@ext;
	}
	$buf .= '</style>';

	if (@$links) {
		foreach my $attr (@$links) {
			delete $attr->{-inline};
			$buf .= "<link\ntype=text/css\nrel=stylesheet";
			while (my ($k, $v) = each %$attr) {
				$v = qq{"$v"} if $v =~ /[\s=]/;
				$buf .= qq{\n$k=$v};
			}
			$buf .= ' />';
		}
		$self->{"-style-$upfx"} = $buf;
	} else {
		$self->{-style_inline} = $buf;
	}
	$self->{-css_map} = $css_map;
}

# returns an HTML fragment with <style> or <link> tags in them
# Called by WwwStream by nearly every HTML page
sub style {
	my ($self, $upfx) = @_;
	$self->{-style_inline} || $self->{"-style-$upfx"} || do {
		stylesheets_prepare($self, $upfx);
		$self->{-style_inline} || $self->{"-style-$upfx"}
	};
}

# /$INBOX/$KEY.css endpoint
# CSS is configured globally for all inboxes, but we access them on
# a per-inbox basis.  This allows administrators to setup per-inbox
# static routes to intercept the request before it hits PSGI
sub get_css ($$) {
	my ($self, $key) = @_;
	my $css_map = $self->{-css_map} || stylesheets_prepare($self, '');
	defined(my $css = $css_map->{$key}) or return r404();
	my $h = [ 'Content-Length', bytes::length($css),
		'Content-Type', 'text/css' ];
	PublicInbox::GitHTTPBackend::cache_one_year($h);
	[ 200, $h, [ $css ] ];
}

1;
