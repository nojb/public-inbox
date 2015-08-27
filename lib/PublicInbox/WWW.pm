# Copyright (C) 2014, Eric Wong <normalperson@yhbt.net> and all contributors
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
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
use PublicInbox::Config;
use URI::Escape qw(uri_escape_utf8 uri_unescape);
use constant SSOMA_URL => 'http://ssoma.public-inbox.org/';
use constant PI_URL => 'http://public-inbox.org/';
our $LISTNAME_RE = qr!\A/([\w\.\-]+)!;
our $pi_config;
BEGIN {
	$pi_config = PublicInbox::Config->new;
}

sub run {
	my ($cgi, $method) = @_;
	my %ctx = (cgi => $cgi, pi_config => $pi_config);
	if ($method !~ /\AGET|HEAD\z/) {
		return r(405, 'Method Not Allowed');
	}
	my $path_info = $cgi->path_info;

	# top-level indices and feeds
	if ($path_info eq '/') {
		r404();
	} elsif ($path_info =~ m!$LISTNAME_RE\z!o) {
		invalid_list(\%ctx, $1) || redirect_list_index($cgi);
	} elsif ($path_info =~ m!$LISTNAME_RE(?:/|/index\.html)?\z!o) {
		invalid_list(\%ctx, $1) || get_index(\%ctx);
	} elsif ($path_info =~ m!$LISTNAME_RE/atom\.xml\z!o) {
		invalid_list(\%ctx, $1) || get_atom(\%ctx);

	# single-message pages
	} elsif ($path_info =~ m!$LISTNAME_RE/m/(\S+)/\z!o) {
		invalid_list_mid(\%ctx, $1, $2) || get_mid_html(\%ctx);
	} elsif ($path_info =~ m!$LISTNAME_RE/m/(\S+)/raw\z!o) {
		invalid_list_mid(\%ctx, $1, $2) || get_mid_txt(\%ctx);
	} elsif ($path_info =~ m!$LISTNAME_RE/m/(\S+)\.txt\z!o) {
		invalid_list_mid(\%ctx, $1, $2) || get_mid_txt(\%ctx);
	} elsif ($path_info =~ m!$LISTNAME_RE/m/(\S+)\.html\z!o) {
		invalid_list_mid(\%ctx, $1, $2) || get_mid_html(\%ctx);

	# full-message page
	} elsif ($path_info =~ m!$LISTNAME_RE/f/(\S+)/\z!o) {
		invalid_list_mid(\%ctx, $1, $2) || get_full_html(\%ctx);
	} elsif ($path_info =~ m!$LISTNAME_RE/f/(\S+)\.html\z!o) {
		invalid_list_mid(\%ctx, $1, $2) || get_full_html(\%ctx);

	# thread display
	} elsif ($path_info =~ m!$LISTNAME_RE/t/(\S+)\.html\z!o) {
		invalid_list_mid(\%ctx, $1, $2) || get_thread(\%ctx);

	} elsif ($path_info =~ m!$LISTNAME_RE/t/(\S+)/mbox(\.gz)?\z!ox ||
	         $path_info =~ m!$LISTNAME_RE/t/(\S+)\.mbox(\.gz)?\z!o) {
		my $sfx = $3;
		invalid_list_mid(\%ctx, $1, $2) ||
			get_thread_mbox(\%ctx, $sfx);

	} elsif ($path_info =~ m!$LISTNAME_RE/f/\S+\.txt\z!o) {
		invalid_list_mid(\%ctx, $1, $2) || redirect_mid_txt(\%ctx);

	# convenience redirects, order matters
	} elsif ($path_info =~ m!$LISTNAME_RE/(m|f|t|s)/(\S+)\z!o) {
		my $pfx = $2;
		invalid_list_mid(\%ctx, $1, $3) || redirect_mid(\%ctx, $2);

	} else {
		r404();
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
		require PublicInbox::Mbox;
		require IO::Compress::Gzip;
	};
}

# private functions below

sub r404 { r(404, 'Not Found') }

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
	$ctx->{mid} = uri_unescape($mid) unless $ret;
	$ret;
}

# /$LISTNAME/atom.xml                       -> Atom feed, includes replies
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
	PublicInbox::Feed::generate_html_index($ctx);
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

# /$LISTNAME/m/$MESSAGE_ID.txt                    -> raw mbox
sub get_mid_txt {
	my ($ctx) = @_;
	my $x = mid2blob($ctx) or return r404();
	require PublicInbox::Mbox;
	PublicInbox::Mbox::emit1($x);
}

# /$LISTNAME/m/$MESSAGE_ID.html                   -> HTML content (short quotes)
sub get_mid_html {
	my ($ctx) = @_;
	my $x = mid2blob($ctx) or return r404();

	require PublicInbox::View;
	my $pfx = msg_pfx($ctx);
	my $foot = footer($ctx);
	require Email::MIME;
	my $mime = Email::MIME->new($x);
	searcher($ctx);
	[ 200, [ 'Content-Type' => 'text/html; charset=UTF-8' ],
	  [ PublicInbox::View::msg_html($ctx, $mime, $pfx, $foot) ] ];
}

# /$LISTNAME/f/$MESSAGE_ID.html                   -> HTML content (fullquotes)
sub get_full_html {
	my ($ctx) = @_;
	my $x = mid2blob($ctx) or return r404();

	require PublicInbox::View;
	my $foot = footer($ctx);
	require Email::MIME;
	my $mime = Email::MIME->new($x);
	searcher($ctx);
	[ 200, [ 'Content-Type' => 'text/html; charset=UTF-8' ],
	  [ PublicInbox::View::msg_html($ctx, $mime, undef, $foot)] ];
}

# /$LISTNAME/t/$MESSAGE_ID.html
sub get_thread {
	my ($ctx) = @_;
	my $srch = searcher($ctx) or return need_search($ctx);
	require PublicInbox::View;
	my $foot = footer($ctx);
	PublicInbox::View::thread_html($ctx, $foot, $srch);
}

sub self_url {
	my ($cgi) = @_;
	ref($cgi) eq 'CGI' ? $cgi->self_url : $cgi->uri->as_string;
}

sub redirect_list_index {
	my ($cgi) = @_;
	do_redirect(self_url($cgi) . "/");
}

sub redirect_mid {
	my ($ctx, $pfx) = @_;
	my $url = self_url($ctx->{cgi});
	my $anchor = '';
	if (lc($pfx) eq 't') {
		$anchor = '#u'; # <u id='#u'> is used to highlight in View.pm
	}
	do_redirect($url . ".html$anchor");
}

# only hit when somebody tries to guess URLs manually:
sub redirect_mid_txt {
	my ($ctx, $pfx) = @_;
	my $listname = $ctx->{listname};
	my $url = self_url($ctx->{cgi});
	$url =~ s!/$listname/f/(\S+\.txt)\z!/$listname/m/$1!;
	do_redirect($url);
}

sub do_redirect {
	my ($url) = @_;
	[ 301,
	  [ Location => $url, 'Content-Type' => 'text/plain' ],
	  [ "Redirecting to $url\n" ]
	]
}

sub ctx_get {
	my ($ctx, $key) = @_;
	my $val = $ctx->{$key};
	(defined $val && length $val) or die "BUG: bad ctx, $key unusable\n";
	$val;
}

sub try_cat {
	my ($path) = @_;
	my $rv;
	if (open(my $fh, '<', $path)) {
		local $/;
		$rv = <$fh>;
		close $fh;
	}
	$rv;
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

sub msg_pfx {
	my ($ctx) = @_;
	my $href = PublicInbox::Hval::ascii_html(uri_escape_utf8($ctx->{mid}));
	"../f/$href.html";
}

# /$LISTNAME/t/$MESSAGE_ID/mbox           -> thread as mbox
# /$LISTNAME/t/$MESSAGE_ID/mbox.gz        -> thread as gzipped mbox
# note: I'm not a big fan of other compression formats since they're
# significantly more expensive on CPU than gzip and less-widely available,
# especially on older systems.  Stick to zlib since that's what git uses.
sub get_thread_mbox {
	my ($ctx, $sfx) = @_;
	my $srch = searcher($ctx) or return need_search($ctx);
	require PublicInbox::Mbox;
	PublicInbox::Mbox::thread_mbox($ctx, $srch, $sfx);
}

1;
