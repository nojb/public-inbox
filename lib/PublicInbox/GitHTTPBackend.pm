# Copyright (C) 2016-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# when no endpoints match, fallback to this and serve a static file
# or smart HTTP.  This is our wrapper for git-http-backend(1)
package PublicInbox::GitHTTPBackend;
use strict;
use warnings;
use Fcntl qw(:seek);
use IO::Handle; # ->flush
use HTTP::Date qw(time2str);
use PublicInbox::Qspawn;
use PublicInbox::Tmpfile;
use PublicInbox::WwwStatic qw(r @NO_CACHE);

# 32 is same as the git-daemon connection limit
my $default_limiter = PublicInbox::Qspawn::Limiter->new(32);

# n.b. serving "description" and "cloneurl" should be innocuous enough to
# not cause problems.  serving "config" might...
my @text = qw[HEAD info/refs info/attributes
	objects/info/(?:http-alternates|alternates|packs)
	cloneurl description];

my @binary = qw!
	objects/[a-f0-9]{2}/[a-f0-9]{38}
	objects/pack/pack-[a-f0-9]{40}\.(?:pack|idx)
	!;

our $ANY = join('|', @binary, @text, 'git-upload-pack');
my $BIN = join('|', @binary);
my $TEXT = join('|', @text);

sub serve {
	my ($env, $git, $path) = @_;

	# Documentation/technical/http-protocol.txt in git.git
	# requires one and exactly one query parameter:
	if ($env->{QUERY_STRING} =~ /\Aservice=git-[A-Za-z0-9_]+-pack\z/ ||
				$path =~ /\Agit-[A-Za-z0-9_]+-pack\z/) {
		my $ok = serve_smart($env, $git, $path);
		return $ok if $ok;
	}

	serve_dumb($env, $git, $path);
}

sub err ($@) {
	my ($env, @msg) = @_;
	$env->{'psgi.errors'}->print(@msg, "\n");
}

my $prev = 0;
my $exp;
sub cache_one_year {
	my ($h) = @_;
	my $t = time + 31536000;
	push @$h, 'Expires', $t == $prev ? $exp : ($exp = time2str($prev = $t)),
		'Cache-Control', 'public, max-age=31536000';
}

sub serve_dumb {
	my ($env, $git, $path) = @_;

	my $h = [];
	my $type;
	if ($path =~ m!\Aobjects/[a-f0-9]{2}/[a-f0-9]{38}\z!) {
		$type = 'application/x-git-loose-object';
		cache_one_year($h);
	} elsif ($path =~ m!\Aobjects/pack/pack-[a-f0-9]{40}\.pack\z!) {
		$type = 'application/x-git-packed-objects';
		cache_one_year($h);
	} elsif ($path =~ m!\Aobjects/pack/pack-[a-f0-9]{40}\.idx\z!) {
		$type = 'application/x-git-packed-objects-toc';
		cache_one_year($h);
	} elsif ($path =~ /\A(?:$TEXT)\z/o) {
		$type = 'text/plain';
		push @$h, @NO_CACHE;
	} else {
		return r(404);
	}
	$path = "$git->{git_dir}/$path";
	PublicInbox::WwwStatic::response($env, $h, $path, $type);
}

sub git_parse_hdr { # {parse_hdr} for Qspawn
	my ($r, $bref, $dumb_args) = @_;
	my $res = parse_cgi_headers($r, $bref) or return; # incomplete
	$res->[0] == 403 ? serve_dumb(@$dumb_args) : $res;
}

# returns undef if 403 so it falls back to dumb HTTP
sub serve_smart {
	my ($env, $git, $path) = @_;
	my %env = %ENV;
	# GIT_COMMITTER_NAME, GIT_COMMITTER_EMAIL
	# may be set in the server-process and are passed as-is
	foreach my $name (qw(QUERY_STRING
				REMOTE_USER REMOTE_ADDR
				HTTP_CONTENT_ENCODING
				HTTP_GIT_PROTOCOL
				CONTENT_TYPE
				SERVER_PROTOCOL
				REQUEST_METHOD)) {
		my $val = $env->{$name};
		$env{$name} = $val if defined $val;
	}
	my $limiter = $git->{-httpbackend_limiter} || $default_limiter;
	$env{GIT_HTTP_EXPORT_ALL} = '1';
	$env{PATH_TRANSLATED} = "$git->{git_dir}/$path";
	my $rdr = input_prepare($env) or return r(500);
	my $qsp = PublicInbox::Qspawn->new([qw(git http-backend)], \%env, $rdr);
	$qsp->psgi_return($env, $limiter, \&git_parse_hdr, [$env, $git, $path]);
}

sub input_prepare {
	my ($env) = @_;

	my $input = $env->{'psgi.input'};
	my $fd = eval { fileno($input) };
	if (defined $fd && $fd >= 0) {
		return { 0 => $fd };
	}
	my $id = "git-http.input.$env->{REMOTE_ADDR}:$env->{REMOTE_PORT}";
	my $in = tmpfile($id);
	unless (defined $in) {
		err($env, "could not open temporary file: $!");
		return;
	}
	my $buf;
	while (1) {
		my $r = $input->read($buf, 8192);
		unless (defined $r) {
			err($env, "error reading input: $!");
			return;
		}
		last if $r == 0;
		unless (print $in $buf) {
			err($env, "error writing temporary file: $!");
			return;
		}
	}
	# ensure it's visible to git-http-backend(1):
	unless ($in->flush) {
		err($env, "error writing temporary file: $!");
		return;
	}
	unless (defined(sysseek($in, 0, SEEK_SET))) {
		err($env, "error seeking temporary file: $!");
		return;
	}
	{ 0 => $in };
}

sub parse_cgi_headers {
	my ($r, $bref) = @_;
	return r(500) unless defined $r && $r >= 0;
	$$bref =~ s/\A(.*?)\r?\n\r?\n//s or return $r == 0 ? r(500) : undef;
	my $h = $1;
	my $code = 200;
	my @h;
	foreach my $l (split(/\r?\n/, $h)) {
		my ($k, $v) = split(/:\s*/, $l, 2);
		if ($k =~ /\AStatus\z/i) {
			($code) = ($v =~ /\b([0-9]+)\b/);
		} else {
			push @h, $k, $v;
		}
	}
	[ $code, \@h ]
}

1;
