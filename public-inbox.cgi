#!/usr/bin/perl -w
# Copyright (C) 2014, Eric Wong <normalperson@yhbt.net> and all contributors
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
#
# We focus on the lowest common denominators here:
# - targeted at text-only console browsers (lynx, w3m, etc..)
# - Only basic HTML, CSS only for line-wrapping <pre> text content for GUIs
# - No JavaScript, graphics or icons allowed.
# - Must not rely on static content
# - UTF-8 is only for user-content, 7-bit US-ASCII for us

use 5.008;
use strict;
use warnings;
use CGI qw(:cgi :escapeHTML -nosticky); # PSGI/FastCGI/mod_perl compat
use Encode qw(decode_utf8);
use PublicInbox::Config;
use URI::Escape qw(uri_escape uri_unescape);
our $LISTNAME_RE = qr!\A/([\w\.\-]+)!;
our $pi_config;
BEGIN {
	$pi_config = PublicInbox::Config->new;
	# TODO: detect and reload config as needed
	if ($ENV{MOD_PERL}) {
		CGI->compile;
	}
}

my $ret = main();

my ($status, $headers, $body) = @$ret;
set_binmode($headers);
if (@ARGV && $ARGV[0] eq 'static') {
	print $body;
} else { # CGI
	print "Status: $status\r\n";
	while (my ($k, $v) = each %$headers) {
		print "$k: $v\r\n";
	}
	print "\r\n", $body;
}

# TODO: plack support

# private functions below

sub main {
	# some servers (Ruby webrick) include scheme://host[:port] here,
	# which confuses CGI.pm when generating self_url.
	# RFC 3875 does not mention REQUEST_URI at all,
	# so nuke it since CGI.pm functions without it.
	delete $ENV{REQUEST_URI};

	my $cgi = CGI->new;
	my %ctx;
	if ($cgi->request_method !~ /\AGET|HEAD\z/) {
		return r("405 Method Not Allowed");
	}
	my $path_info = decode_utf8($cgi->path_info);

	# top-level indices and feeds
	if ($path_info eq "/") {
		r404();
	} elsif ($path_info =~ m!$LISTNAME_RE\z!o) {
		invalid_list(\%ctx, $1) || redirect_list_index(\%ctx, $cgi);
	} elsif ($path_info =~ m!$LISTNAME_RE(?:/|/index\.html)?\z!o) {
		invalid_list(\%ctx, $1) || get_index(\%ctx, $cgi, 0);
	} elsif ($path_info =~ m!$LISTNAME_RE/atom\.xml\z!o) {
		invalid_list(\%ctx, $1) || get_atom(\%ctx, $cgi, 0);

	# single-message pages
	} elsif ($path_info =~ m!$LISTNAME_RE/m/(\S+)\.txt\z!o) {
		invalid_list_mid(\%ctx, $1, $2) || get_mid_txt(\%ctx, $cgi);
	} elsif ($path_info =~ m!$LISTNAME_RE/m/(\S+)\.html\z!o) {
		invalid_list_mid(\%ctx, $1, $2) || get_mid_html(\%ctx, $cgi);

	# full-message page
	} elsif ($path_info =~ m!$LISTNAME_RE/f/(\S+)\.html\z!o) {
		invalid_list_mid(\%ctx, $1, $2) || get_full_html(\%ctx, $cgi);

	# convenience redirects, order matters
	} elsif ($path_info =~ m!$LISTNAME_RE/(?:m|f)/(\S+)\z!o) {
		invalid_list_mid(\%ctx, $1, $2) || redirect_mid(\%ctx, $cgi);

	} else {
		r404();
	}
}

sub r404 { r("404 Not Found") }

# simple response for errors
sub r { [ $_[0], { 'Content-Type' => 'text/plain' }, $_[0]."\n" ] }

# returns undef if valid, array ref response if invalid
sub invalid_list {
	my ($ctx, $listname) = @_;
	my $git_dir = $pi_config->get($listname, "mainrepo");
	if (defined $git_dir) {
		$ctx->{git_dir} = $git_dir;
		$ctx->{listname} = $listname;
		return undef;
	}
	r404();
}

# returns undef if valid, array ref response if invalid
sub invalid_list_mid {
	my ($ctx, $listname, $mid) = @_;
	my $ret = invalid_list($ctx, $listname, $mid) and return $ret;
	$ctx->{mid} = uri_unescape($mid);
	undef;
}

# /$LISTNAME/atom.xml                       -> Atom feed, includes replies
sub get_atom {
	my ($ctx, $cgi, $top) = @_;
	require PublicInbox::Feed;
	[ '200 OK', { 'Content-Type' => 'application/xml' },
	  PublicInbox::Feed->generate({
			git_dir => $ctx->{git_dir},
			listname => $ctx->{listname},
			pi_config => $pi_config,
			cgi => $cgi,
			top => $top,
		})
	];
}

# /$LISTNAME/?r=$GIT_COMMIT                 -> HTML only
sub get_index {
	my ($ctx, $cgi, $top) = @_;
	require PublicInbox::Feed;
	[ '200 OK', { 'Content-Type' => 'text/html' },
	  PublicInbox::Feed->generate_html_index({
			git_dir => $ctx->{git_dir},
			listname => $ctx->{listname},
			pi_config => $pi_config,
			cgi => $cgi,
			top => $top,
		})
	];
}

# just returns a string ref for the blob in the current ctx
sub mid2blob {
	my ($ctx) = @_;
	local $ENV{GIT_DIR} = $ctx->{git_dir};
	require Digest::SHA;
	my $hex = Digest::SHA::sha1_hex($ctx->{mid});
	$hex =~ /\A([a-f0-9]{2})([a-f0-9]{38})\z/i or
			die "BUG: not a SHA-1 hex: $hex";
	my $blob = `git cat-file blob HEAD:$1/$2 2>/dev/null`;
	$? == 0 ? \$blob : undef;
}

# /$LISTNAME/m/$MESSAGE_ID.txt                    -> raw original
sub get_mid_txt {
	my ($ctx, $cgi) = @_;
	my $x = mid2blob($ctx);
	$x ? [ "200 OK", {'Content-Type' => 'text/plain'}, $$x ] : r404();
}

# /$LISTNAME/m/$MESSAGE_ID.html                   -> HTML content (short quotes)
sub get_mid_html {
	my ($ctx, $cgi) = @_;
	my $x = mid2blob($ctx);
	return r404() unless $x;

	require PublicInbox::View;
	my $mid_href = PublicInbox::Hval::ascii_html(uri_escape($ctx->{mid}));
	my $pfx = "../f/$mid_href.html";
	require Email::MIME;
	[ "200 OK", {'Content-Type' => 'text/html'},
		PublicInbox::View->as_html(Email::MIME->new($$x), $pfx)];
}

# /$LISTNAME/f/$MESSAGE_ID.html                   -> HTML content (fullquotes)
sub get_full_html {
	my ($ctx, $cgi) = @_;
	my $x = mid2blob($ctx);
	return r404() unless $x;
	require PublicInbox::View;
	require Email::MIME;
	[ "200 OK", {'Content-Type' => 'text/html'},
		PublicInbox::View->as_html(Email::MIME->new($$x))];
}

sub redirect_list_index {
	my ($ctx, $cgi) = @_;
	do_redirect($cgi->self_url . "/");
}

sub redirect_mid {
	my ($ctx, $cgi) = @_;
	my $url = $cgi->self_url;
	$url =~ s!/f/!/m/!;
	do_redirect($url . '.html');
}

sub do_redirect {
	my ($url) = @_;
	[ '301 Moved Permanently',
	  { Location => $url, 'Content-Type' => 'text/plain' },
	  "Redirecting to $url\n"
	]
}

# only used for CGI and static file generation modes
sub set_binmode {
	my ($headers) = @_;
	if ($headers->{'Content-Type'} eq 'text/plain') {
		# no way to validate raw messages, mixed encoding is possible.
		binmode STDOUT;
	} else { # strict encoding for HTML and XML
		binmode STDOUT, ':encoding(UTF-8)';
	}
}
