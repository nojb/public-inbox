# Copyright (C) 2014-2015 all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
#
# Main web interface for mailing list archives
#
# We focus on the lowest common denominators here:
# - targeted at text-only console browsers (w3m, links, etc..)
# - Only basic HTML, CSS only for line-wrapping <pre> text content for GUIs
# - No JavaScript, graphics or icons allowed.
# - Must not rely on static content
# - UTF-8 is only for user-content, 7-bit US-ASCII for us
package PublicInbox::WWW;
use 5.008;
use strict;
use warnings;
use PublicInbox::Config qw(try_cat);
use URI::Escape qw(uri_escape_utf8 uri_unescape);
use constant SSOMA_URL => 'http://ssoma.public-inbox.org/';
use constant PI_URL => 'http://public-inbox.org/';
our $LISTNAME_RE = qr!\A/([\w\.\-]+)!;
our $MID_RE = qr!([^/]+)!;
our $END_RE = qr!(f/|T/|t/|t\.mbox(?:\.gz)?|t\.atom|raw|)!;
our $pi_config;

sub run {
	my ($cgi, $method) = @_;
	$pi_config ||= PublicInbox::Config->new;
	my $ctx = { cgi => $cgi, pi_config => $pi_config };
	if ($method !~ /\AGET|HEAD\z/) {
		return r(405, 'Method Not Allowed');
	}
	my $path_info = $cgi->path_info;

	# top-level indices and feeds
	if ($path_info eq '/') {
		r404();
	} elsif ($path_info =~ m!$LISTNAME_RE\z!o) {
		invalid_list($ctx, $1) || r301($ctx, $1);
	} elsif ($path_info =~ m!$LISTNAME_RE(?:/|/index\.html)?\z!o) {
		invalid_list($ctx, $1) || get_index($ctx);
	} elsif ($path_info =~ m!$LISTNAME_RE/(?:atom\.xml|new\.atom)\z!o) {
		invalid_list($ctx, $1) || get_atom($ctx);

	} elsif ($path_info =~ m!$LISTNAME_RE/$MID_RE/$END_RE\z!o) {
		msg_page($ctx, $1, $2, $3);

	# in case people leave off the trailing slash:
	} elsif ($path_info =~ m!$LISTNAME_RE/$MID_RE/(f|T|t)\z!o) {
		r301($ctx, $1, $2, $3 eq 't' ? 't/#u' : $3);

	# convenience redirects order matters
	} elsif ($path_info =~ m!$LISTNAME_RE/([^/]{2,})\z!o) {
		r301($ctx, $1, $2);

	} else {
		legacy_redirects($ctx, $path_info);
	}
}

# for CoW-friendliness, MOOOOO!
sub preload {
	require PublicInbox::Feed;
	require PublicInbox::View;
	require PublicInbox::Thread;
	require PublicInbox::GitCatFile;
	require Email::MIME;
	require Digest::SHA;
	require POSIX;

	eval {
		require PublicInbox::Search;
		require PublicInbox::SearchView;
		require PublicInbox::Mbox;
		require IO::Compress::Gzip;
	};
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
sub invalid_list {
	my ($ctx, $listname) = @_;
	my $git_dir = $pi_config->get($listname, "mainrepo");
	if (defined $git_dir) {
		$ctx->{git_dir} = $git_dir;
		$ctx->{listname} = $listname;
		return;
	}
	r404();
}

# returns undef if valid, array ref response if invalid
sub invalid_list_mid {
	my ($ctx, $listname, $mid) = @_;
	my $ret = invalid_list($ctx, $listname, $mid);
	return $ret if $ret;

	$ctx->{mid} = $mid = uri_unescape($mid);
	if ($mid =~ /\A[a-f0-9]{40}\z/) {
		if ($mid = mid2blob($ctx)) {
			require Email::Simple;
			use PublicInbox::MID qw/mid_clean/;
			$mid = Email::Simple->new($mid);
			$ctx->{mid} = mid_clean($mid->header('Message-ID'));
		}
	}
	undef;
}

# /$LISTNAME/new.atom                     -> Atom feed, includes replies
sub get_atom {
	my ($ctx) = @_;
	require PublicInbox::Feed;
	PublicInbox::Feed::generate($ctx);
}

# /$LISTNAME/?r=$GIT_COMMIT                 -> HTML only
sub get_index {
	my ($ctx) = @_;
	require PublicInbox::Feed;
	my $srch = searcher($ctx);
	footer($ctx);
	if (defined $ctx->{cgi}->param('q')) {
		require PublicInbox::SearchView;
		PublicInbox::SearchView::sres_top_html($ctx);
	} else {
		PublicInbox::Feed::generate_html_index($ctx);
	}
}

# just returns a string ref for the blob in the current ctx
sub mid2blob {
	my ($ctx) = @_;
	require PublicInbox::MID;
	my $path = PublicInbox::MID::mid2path($ctx->{mid});
	my @cmd = ('git', "--git-dir=$ctx->{git_dir}",
			qw(cat-file blob), "HEAD:$path");
	my $pid = open my $fh, '-|';
	defined $pid or die "fork failed: $!\n";
	if ($pid == 0) {
		open STDERR, '>', '/dev/null'; # ignore errors
		exec @cmd or die "exec failed: $!\n";
	} else {
		my $blob = eval { local $/; <$fh> };
		close $fh;
		$? == 0 ? \$blob : undef;
	}
}

# /$LISTNAME/$MESSAGE_ID/raw                    -> raw mbox
sub get_mid_txt {
	my ($ctx) = @_;
	my $x = mid2blob($ctx) or return r404($ctx);
	require PublicInbox::Mbox;
	PublicInbox::Mbox::emit1($ctx, $x);
}

# /$LISTNAME/$MESSAGE_ID/                   -> HTML content (short quotes)
sub get_mid_html {
	my ($ctx) = @_;
	my $x = mid2blob($ctx) or return r404($ctx);

	require PublicInbox::View;
	my $foot = footer($ctx);
	require Email::MIME;
	my $mime = Email::MIME->new($x);
	searcher($ctx);
	[ 200, [ 'Content-Type' => 'text/html; charset=UTF-8' ],
	  [ PublicInbox::View::msg_html($ctx, $mime, 'f/', $foot) ] ];
}

# /$LISTNAME/$MESSAGE_ID/f/                   -> HTML content (fullquotes)
sub get_full_html {
	my ($ctx) = @_;
	my $x = mid2blob($ctx) or return r404($ctx);

	require PublicInbox::View;
	my $foot = footer($ctx);
	require Email::MIME;
	my $mime = Email::MIME->new($x);
	searcher($ctx);
	[ 200, [ 'Content-Type' => 'text/html; charset=UTF-8' ],
	  [ PublicInbox::View::msg_html($ctx, $mime, undef, $foot)] ];
}

# /$LISTNAME/$MESSAGE_ID/t/
sub get_thread {
	my ($ctx, $flat) = @_;
	my $srch = searcher($ctx) or return need_search($ctx);
	require PublicInbox::View;
	my $foot = footer($ctx);
	$ctx->{flat} = $flat;
	PublicInbox::View::thread_html($ctx, $foot, $srch);
}

sub self_url {
	my ($cgi) = @_;
	ref($cgi) eq 'CGI' ? $cgi->self_url : $cgi->uri->as_string;
}

sub ctx_get {
	my ($ctx, $key) = @_;
	my $val = $ctx->{$key};
	(defined $val && $val ne '') or die "BUG: bad ctx, $key unusable\n";
	$val;
}

sub footer {
	my ($ctx) = @_;
	return '' unless $ctx;
	my $git_dir = ctx_get($ctx, 'git_dir');

	# favor user-supplied footer
	my $footer = try_cat("$git_dir/public-inbox/footer.html");
	if (defined $footer) {
		chomp $footer;
		$ctx->{footer} = $footer;
		return $footer;
	}

	# auto-generate a footer
	my $listname = ctx_get($ctx, 'listname');
	my $desc = try_cat("$git_dir/description");
	$desc = '$GIT_DIR/description missing' unless defined $desc;
	chomp $desc;

	my $urls = try_cat("$git_dir/cloneurl");
	my @urls = split(/\r?\n/, $urls || '');
	my $nurls = scalar @urls;
	if ($nurls == 0) {
		$urls = '($GIT_DIR/cloneurl missing)';
	} elsif ($nurls == 1) {
		$urls = "git URL for <a\nhref=\"" . SSOMA_URL .
			'">ssoma</a>: ' . $urls[0];
	} else {
		$urls = "git URLs for <a\nhref=\"" . SSOMA_URL .
			"\">ssoma</a>:\n" . join("\n", map { "\t$_" } @urls);
	}

	my $addr = $pi_config->get($listname, 'address');
	if (ref($addr) eq 'ARRAY') {
		$addr = $addr->[0]; # first address is primary
	}

	$addr = "<a\nhref=\"mailto:$addr\">$addr</a>";

	$ctx->{footer} = join("\n",
		'- ' . $desc,
		"A <a\nhref=\"" . PI_URL .  '">public-inbox</a>, ' .
			'anybody may post in plain-text (not HTML):',
		$addr,
		$urls
	);
}

# search support is optional, returns undef if Xapian is not installed
# or not configured for the given GIT_DIR
sub searcher {
	my ($ctx) = @_;
	eval {
		require PublicInbox::Search;
		$ctx->{srch} = PublicInbox::Search->new($ctx->{git_dir});
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

# /$LISTNAME/$MESSAGE_ID/t.mbox           -> thread as mbox
# /$LISTNAME/$MESSAGE_ID/t.mbox.gz        -> thread as gzipped mbox
# note: I'm not a big fan of other compression formats since they're
# significantly more expensive on CPU than gzip and less-widely available,
# especially on older systems.  Stick to zlib since that's what git uses.
sub get_thread_mbox {
	my ($ctx, $sfx) = @_;
	my $srch = searcher($ctx) or return need_search($ctx);
	require PublicInbox::Mbox;
	PublicInbox::Mbox::thread_mbox($ctx, $srch, $sfx);
}


# /$LISTNAME/$MESSAGE_ID/t.atom		  -> thread as Atom feed
sub get_thread_atom {
	my ($ctx) = @_;
	searcher($ctx) or return need_search($ctx);
	$ctx->{self_url} = self_url($ctx->{cgi});
	require PublicInbox::Feed;
	PublicInbox::Feed::generate_thread_atom($ctx);
}

sub legacy_redirects {
	my ($ctx, $path_info) = @_;

	# single-message pages
	if ($path_info =~ m!$LISTNAME_RE/m/(\S+)/\z!o) {
		r301($ctx, $1, $2);
	} elsif ($path_info =~ m!$LISTNAME_RE/m/(\S+)/raw\z!o) {
		r301($ctx, $1, $2, 'raw');

	} elsif ($path_info =~ m!$LISTNAME_RE/f/(\S+)/\z!o) {
		r301($ctx, $1, $2, 'f/');

	# thread display
	} elsif ($path_info =~ m!$LISTNAME_RE/t/(\S+)/\z!o) {
		r301($ctx, $1, $2, 't/#u');

	} elsif ($path_info =~ m!$LISTNAME_RE/t/(\S+)/mbox(\.gz)?\z!o) {
		r301($ctx, $1, $2, "t.mbox$3");

	# even older legacy redirects
	} elsif ($path_info =~ m!$LISTNAME_RE/m/(\S+)\.html\z!o) {
		r301($ctx, $1, $2);

	} elsif ($path_info =~ m!$LISTNAME_RE/t/(\S+)\.html\z!o) {
		r301($ctx, $1, $2, 't/#u');

	} elsif ($path_info =~ m!$LISTNAME_RE/f/(\S+)\.html\z!o) {
		r301($ctx, $1, $2, 'f/');

	} elsif ($path_info =~ m!$LISTNAME_RE/(?:m|f)/(\S+)\.txt\z!o) {
		r301($ctx, $1, $2, 'raw');

	} elsif ($path_info =~ m!$LISTNAME_RE/t/(\S+)(\.mbox(?:\.gz)?)\z!o) {
		r301($ctx, $1, $2, "t$3");

	# legacy convenience redirects, order still matters
	} elsif ($path_info =~ m!$LISTNAME_RE/m/(\S+)\z!o) {
		r301($ctx, $1, $2);
	} elsif ($path_info =~ m!$LISTNAME_RE/t/(\S+)\z!o) {
		r301($ctx, $1, $2, 't/#u');
	} elsif ($path_info =~ m!$LISTNAME_RE/f/(\S+)\z!o) {
		r301($ctx, $1, $2, 'f/');

	# some Message-IDs have slashes in them and the HTTP server
	# may try to be clever and unescape them :<
	} elsif ($path_info =~ m!$LISTNAME_RE/(\S+/\S+)/$END_RE\z!o) {
		msg_page($ctx, $1, $2, $3);

	# in case people leave off the trailing slash:
	} elsif ($path_info =~ m!$LISTNAME_RE/(\S+/\S+)/(f|T|t)\z!o) {
		r301($ctx, $1, $2, $3 eq 't' ? 't/#u' : $3);
	} else {
		r404();
	}
}

sub r301 {
	my ($ctx, $listname, $mid, $suffix) = @_;
	my $cgi = $ctx->{cgi};
	my $url;
	if (ref($cgi) eq 'CGI') {
		$url = $cgi->url(-base) . '/';
	} else {
		$url = $cgi->base->as_string;
	}

	$url .= $listname . '/';
	$url .= (uri_escape_utf8($mid) . '/') if (defined $mid);
	$url .= $suffix if (defined $suffix);

	[ 301,
	  [ Location => $url, 'Content-Type' => 'text/plain' ],
	  [ "Redirecting to $url\n" ] ]
}

sub msg_page {
	my ($ctx, $list, $mid, $e) = @_;
	unless (invalid_list_mid($ctx, $list, $mid)) {
		'' eq $e and return get_mid_html($ctx);
		't/' eq $e and return get_thread($ctx);
		't.atom' eq $e and return get_thread_atom($ctx);
		't.mbox' eq $e and return get_thread_mbox($ctx);
		't.mbox.gz' eq $e and return get_thread_mbox($ctx, '.gz');
		'T/' eq $e and return get_thread($ctx, 1);
		'raw' eq $e and return get_mid_txt($ctx);
		'f/' eq $e and return get_full_html($ctx);
	}
	r404($ctx);
}

1;
