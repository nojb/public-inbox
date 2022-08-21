# Copyright (C) all contributors <meta@public-inbox.org>
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
use strict;
use v5.10.1;
use PublicInbox::Config;
use PublicInbox::Hval;
use URI::Escape qw(uri_unescape);
use PublicInbox::MID qw(mid_escape);
use PublicInbox::GitHTTPBackend;
use PublicInbox::UserContent;
use PublicInbox::WwwStatic qw(r path_info_raw);
use PublicInbox::Eml;

# TODO: consider a routing tree now that we have more endpoints:
our $INBOX_RE = qr!\A/([\w\-][\w\.\-\+]*)!;
our $MID_RE = qr!([^/]+)!;
our $END_RE = qr!(T/|t/|t\.mbox(?:\.gz)?|t\.atom|raw|)!;
our $ATTACH_RE = qr!([0-9][0-9\.]*)-($PublicInbox::Hval::FN)!;
our $OID_RE = qr![a-f0-9]{7,}!;

sub new {
	my ($class, $pi_cfg) = @_;
	bless { pi_cfg => $pi_cfg // PublicInbox::Config->new }, $class;
}

# backwards compatibility, do not use
sub run {
	my ($req, $method) = @_;
	PublicInbox::WWW->new->call($req->env);
}

sub call {
	my ($self, $env) = @_;
	my $ctx = { env => $env, www => $self };

	# we don't care about multi-value
	%{$ctx->{qp}} = map {
		utf8::decode($_);
		tr/+/ /;
		my ($k, $v) = split(/=/, $_, 2);
		# none of the keys we care about will need escaping
		($k // '', uri_unescape($v // ''))
	} split(/[&;]+/, $env->{QUERY_STRING});

	my $path_info = path_info_raw($env);
	my $method = $env->{REQUEST_METHOD};

	if ($method eq 'POST') {
		if ($path_info =~ m!$INBOX_RE/(?:(?:git/)?([0-9]+)(?:\.git)?/)?
					(git-upload-pack)\z!x) {
			my ($epoch, $path) = ($2, $3);
			return invalid_inbox($ctx, $1) ||
				serve_git($ctx, $epoch, $path);
		} elsif ($path_info =~ m!$INBOX_RE/(\w+)\.sql\.gz\z!o) {
			return get_altid_dump($ctx, $1, $2);
		} elsif ($path_info =~ m!$INBOX_RE/$MID_RE/$ATTACH_RE\z!o) {
			my ($idx, $fn) = ($3, $4);
			return invalid_inbox_mid($ctx, $1, $2) ||
				get_attach($ctx, $idx, $fn);
		} elsif ($path_info =~ m!$INBOX_RE/!o) {
			return invalid_inbox($ctx, $1) || mbox_results($ctx);
		}
	}
	elsif ($method !~ /\A(?:GET|HEAD)\z/) {
		return r(405);
	}

	# top-level indices and feeds
	if ($path_info eq '/') {
		require PublicInbox::WwwListing;
		PublicInbox::WwwListing->response($ctx);
	} elsif ($path_info eq '/manifest.js.gz') {
		require PublicInbox::ManifestJsGz;
		PublicInbox::ManifestJsGz->response($ctx);
	} elsif ($path_info =~ m!$INBOX_RE\z!o) {
		invalid_inbox($ctx, $1) || r301($ctx, $1);
	} elsif ($path_info =~ m!$INBOX_RE(?:/|/index\.html)?\z!o) {
		invalid_inbox($ctx, $1) || get_index($ctx);
	} elsif ($path_info =~ m!$INBOX_RE/(?:atom\.xml|new\.atom)\z!o) {
		invalid_inbox($ctx, $1) || get_atom($ctx);
	} elsif ($path_info =~ m!$INBOX_RE/new\.html\z!o) {
		invalid_inbox($ctx, $1) || get_new($ctx);
	} elsif ($path_info =~ m!$INBOX_RE/description\z!o) {
		get_description($ctx, $1);
	} elsif ($path_info =~ m!$INBOX_RE/(?:(?:git/)?([0-9]+)(?:\.git)?/)?
				($PublicInbox::GitHTTPBackend::ANY)\z!ox) {
		my ($epoch, $path) = ($2, $3);
		invalid_inbox($ctx, $1) || serve_git($ctx, $epoch, $path);
	} elsif ($path_info =~ m!$INBOX_RE/([a-zA-Z0-9_\-]+).mbox\.gz\z!o) {
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
	} elsif ($path_info =~ m!$INBOX_RE/([a-zA-Z0-9_\-\.]+)\.css\z!o) {
		get_css($ctx, $1, $2);
	} elsif ($path_info =~ m!$INBOX_RE/manifest\.js\.gz\z!o) {
		get_inbox_manifest($ctx, $1, $2);
	} elsif ($path_info =~ m!$INBOX_RE/($OID_RE)/s/\z!o) {
		get_vcs_object($ctx, $1, $2);
	} elsif ($path_info =~ m!$INBOX_RE/($OID_RE)/s/
				($PublicInbox::Hval::FN)\z!ox) {
		get_vcs_object($ctx, $1, $2, $3);
	} elsif ($path_info =~ m!$INBOX_RE/($OID_RE)/s\z!o) {
		r301($ctx, $1, $2, 's/');
	} elsif ($path_info =~ m!$INBOX_RE/(\w+)\.sql\.gz\z!o) {
		get_altid_dump($ctx, $1, $2);
	# convenience redirects order matters
	} elsif ($path_info =~ m!$INBOX_RE/([^/]{2,})\z!o) {
		r301($ctx, $1, $2);
	} elsif ($path_info =~ m!\A/\+/([a-zA-Z0-9_\-\.]+)\.css\z!) {
		get_css($ctx, undef, $1); # for WwwListing
	} else {
		legacy_redirects($ctx, $path_info);
	}
}

# for CoW-friendliness, MOOOOO!  Even for single-process setups,
# we want to get all immortal allocations done early to avoid heap
# fragmentation since common allocators favor a large contiguous heap.
sub preload {
	my ($self) = @_;

	# populate caches used by Encode internally, since emails
	# may show up with any encoding.
	require Encode;
	Encode::find_encoding($_) for Encode->encodings(':all');

	require PublicInbox::ExtMsg;
	require PublicInbox::Feed;
	require PublicInbox::View;
	require PublicInbox::SearchThread;
	require PublicInbox::Eml;
	require PublicInbox::Mbox;
	require PublicInbox::ViewVCS;
	require PublicInbox::WwwText;
	require PublicInbox::WwwAttach;
	eval {
		require PublicInbox::Search;
		PublicInbox::Search::load_xapian();
	};
	for (qw(SearchView MboxGz WwwAltId)) {
		eval "require PublicInbox::$_;";
	}
	if (ref($self)) {
		my $pi_cfg = $self->{pi_cfg};
		if (defined($pi_cfg->{'publicinbox.cgitrc'})) {
			$pi_cfg->limiter('-cgit');
		}
		$pi_cfg->ALL and require PublicInbox::Isearch;
		$self->cgit;
		$self->stylesheets_prepare($_) for ('', '../', '../../');
		$self->news_www;
	}
}

# private functions below

sub r404 {
	my ($ctx) = @_;
	if ($ctx && $ctx->{mid}) {
		require PublicInbox::ExtMsg;
		return PublicInbox::ExtMsg::ext_msg($ctx);
	}
	r(404);
}

sub news_cgit_fallback ($) {
	my ($ctx) = @_;
	my $www = $ctx->{www};
	my $env = $ctx->{env};
	my $res = $www->news_www->call($env);
	$res->[0] == 404 ? $www->cgit->call($env) : $res;
}

# returns undef if valid, array ref response if invalid
sub invalid_inbox ($$) {
	my ($ctx, $inbox) = @_;
	my $ibx = $ctx->{www}->{pi_cfg}->lookup_name($inbox) //
			$ctx->{www}->{pi_cfg}->lookup_ei($inbox);
	if (defined $ibx) {
		$ctx->{ibx} = $ibx;
		return;
	}

	# sometimes linkifiers (not ours!) screw up automatic link
	# generation and link things intended for nntp:// to https?://,
	# so try to infer links and redirect them to the appropriate
	# list URL.
	news_cgit_fallback($ctx);
}

# returns undef if valid, array ref response if invalid
sub invalid_inbox_mid {
	my ($ctx, $inbox, $mid_ue) = @_;
	my $ret = invalid_inbox($ctx, $inbox);
	return $ret if $ret;

	my $mid = $ctx->{mid} = uri_unescape($mid_ue);
	my $ibx = $ctx->{ibx};
	if ($mid =~ m!\A([a-f0-9]{2})([a-f0-9]{38})\z!) {
		my ($x2, $x38) = ($1, $2);
		# this is horrifically wasteful for legacy URLs:
		my $str = $ctx->{ibx}->msg_by_path("$x2/$x38") or return;
		my $s = PublicInbox::Eml->new($str);
		$mid = PublicInbox::MID::mid_clean($s->header_raw('Message-ID'));
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
	PublicInbox::Mbox::emit_raw($ctx) || r(404);
}

# /$INBOX/$MESSAGE_ID/                   -> HTML content (short quotes)
sub get_mid_html {
	my ($ctx) = @_;
	require PublicInbox::View;
	PublicInbox::View::msg_page($ctx) || r404($ctx);
}

# /$INBOX/$MESSAGE_ID/t/
sub get_thread {
	my ($ctx, $flat) = @_;
	$ctx->{ibx}->over or return need($ctx, 'Overview');
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
# /$INBOX/$GIT_OBJECT_ID/s/
# /$INBOX/$GIT_OBJECT_ID/s/$FILENAME
sub get_vcs_object ($$$;$) {
	my ($ctx, $inbox, $oid, $filename) = @_;
	my $r404 = invalid_inbox($ctx, $inbox);
	return $r404 if $r404 || !$ctx->{www}->{pi_cfg}->repo_objs($ctx->{ibx});
	require PublicInbox::ViewVCS;
	PublicInbox::ViewVCS::show($ctx, $oid, $filename);
}

sub get_altid_dump {
	my ($ctx, $inbox, $altid_pfx) =@_;
	my $r404 = invalid_inbox($ctx, $inbox);
	return $r404 if $r404;
	eval { require PublicInbox::WwwAltId } or return need($ctx, 'sqlite3');
	PublicInbox::WwwAltId::sqldump($ctx, $altid_pfx);
}

sub need {
	my ($ctx, $extra) = @_;
	require PublicInbox::WwwStream;
	PublicInbox::WwwStream::html_oneshot($ctx, 501, \<<EOF);
<pre>$extra is not available for this public-inbox
<a\nhref="../">Return to index</a></pre>
EOF
}

# /$INBOX/$MESSAGE_ID/t.mbox           -> thread as mbox
# /$INBOX/$MESSAGE_ID/t.mbox.gz        -> thread as gzipped mbox
# note: I'm not a big fan of other compression formats since they're
# significantly more expensive on CPU than gzip and less-widely available,
# especially on older systems.  Stick to zlib since that's what git uses.
sub get_thread_mbox {
	my ($ctx, $sfx) = @_;
	my $over = $ctx->{ibx}->over or return need($ctx, 'Overview');
	require PublicInbox::Mbox;
	PublicInbox::Mbox::thread_mbox($ctx, $over, $sfx);
}


# /$INBOX/$MESSAGE_ID/t.atom		  -> thread as Atom feed
sub get_thread_atom {
	my ($ctx) = @_;
	$ctx->{ibx}->over or return need($ctx, 'Overview');
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
		news_cgit_fallback($ctx);
	}
}

sub r301 {
	my ($ctx, $inbox, $mid_ue, $suffix) = @_;
	my $ibx = $ctx->{ibx};
	unless ($ibx) {
		my $r404 = invalid_inbox($ctx, $inbox);
		return $r404 if $r404;
		$ibx = $ctx->{ibx};
	}
	my $url = $ibx->base_url($ctx->{env});
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
	my ($ctx, $epoch, $path) = @_;
	my $env = $ctx->{env};
	my $ibx = $ctx->{ibx};
	my $git = defined $epoch ? $ibx->git_epoch($epoch) : $ibx->git;
	$git ? PublicInbox::GitHTTPBackend::serve($env, $git, $path) : r404();
}

sub mbox_results {
	my ($ctx) = @_;
	if ($ctx->{env}->{QUERY_STRING} =~ /(?:\A|[&;])q=/) {
		$ctx->{ibx}->isrch or return need($ctx, 'search');
		require PublicInbox::SearchView;
		return PublicInbox::SearchView::mbox_results($ctx);
	}
	r404();
}

sub serve_mbox_range {
	my ($ctx, $inbox, $range) = @_;
	invalid_inbox($ctx, $inbox) || eval {
		require PublicInbox::Mbox;
		PublicInbox::Mbox::emit_range($ctx, $range);
	}
}

sub news_www {
	my ($self) = @_;
	$self->{news_www} //= do {
		require PublicInbox::NewsWWW;
		PublicInbox::NewsWWW->new($self->{pi_cfg});
	}
}

sub cgit {
	my ($self) = @_;
	$self->{cgit} //= do {
		my $pi_cfg = $self->{pi_cfg};

		if (defined($pi_cfg->{'publicinbox.cgitrc'})) {
			require PublicInbox::Cgit;
			PublicInbox::Cgit->new($pi_cfg);
		} else {
			require Plack::Util;
			Plack::Util::inline_object(call => sub { r404() });
		}
	}
}

# GET $INBOX/manifest.js.gz
sub get_inbox_manifest ($$$) {
	my ($ctx, $inbox, $key) = @_;
	my $r404 = invalid_inbox($ctx, $inbox);
	return $r404 if $r404;
	require PublicInbox::ManifestJsGz;
	PublicInbox::ManifestJsGz::per_inbox($ctx);
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
	my $stylesheets = $self->{pi_cfg}->{css} || [];
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
			my $fn = $_;
			my ($key) = (m!([^/]+?)(?:\.css)?\z!i);
			if ($key !~ /\A[a-zA-Z0-9_\-\.]+\z/) {
				warn "ignoring $fn, non-ASCII word character\n";
				next;
			}
			open(my $fh, '<', $fn) or do {
				warn "failed to open $fn: $!\n";
				next;
			};
			my $ctime = 0;
			my $local = do { local $/; <$fh> };
			if ($local =~ /\S/) {
				$ctime = sprintf('%x',(stat($fh))[10]);
				$local = $mini->($local);
			}

			# do not let BOFHs override userContent.css:
			if ($local =~ /!\s*important\b/i) {
				warn "ignoring $fn since it uses `!important'\n";
				next;
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

# /$INBOX/$KEY.css and /+/$KEY.css endpoints
# CSS is configured globally for all inboxes, but we access them on
# a per-inbox basis.  This allows administrators to setup per-inbox
# static routes to intercept the request before it hits PSGI
# inbox == undef => top-level WwwListing
sub get_css ($$$) {
	my ($ctx, $inbox, $key) = @_;
	my $r404 = defined($inbox) ? invalid_inbox($ctx, $inbox) : undef;
	return $r404 if $r404;
	my $self = $ctx->{www};
	my $css_map = $self->{-css_map} ||
		stylesheets_prepare($self, defined($inbox) ? '' : '+/');
	my $css = $css_map->{$key};
	if (!defined($css) && defined($inbox) && $key eq 'userContent') {
		my $env = $ctx->{env};
		$css = PublicInbox::UserContent::sample($ctx->{ibx}, $env);
	}
	defined $css or return r404();
	my $h = [ 'Content-Length', length($css), 'Content-Type', 'text/css' ];
	PublicInbox::GitHTTPBackend::cache_one_year($h);
	[ 200, $h, [ $css ] ];
}

sub get_description {
	my ($ctx, $inbox) = @_;
	invalid_inbox($ctx, $inbox) || do {
		my $d = $ctx->{ibx}->description . "\n";
		utf8::encode($d);
		[ 200, [ 'Content-Length', length($d),
			'Content-Type', 'text/plain' ], [ $d ] ];
	};
}

sub event_step { # called via requeue
	my ($self) = @_;
	# gzf = PublicInbox::GzipFilter == $ctx
	my $gzf = shift(@{$self->{-low_prio_q}}) // return;
	PublicInbox::DS::requeue($self) if scalar(@{$self->{-low_prio_q}});
	my $http = $gzf->{env}->{'psgix.io'}; # PublicInbox::HTTP
	$http->next_step($gzf->can('async_next'));
}

1;
