# Copyright (C) 2019-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Provide an HTTP-accessible listing of inboxes.
# Used by PublicInbox::WWW
package PublicInbox::WwwListing;
use strict;
use warnings;
use PublicInbox::Hval qw(ascii_html prurl);
use PublicInbox::Linkify;
use PublicInbox::View;
use PublicInbox::Inbox;
use bytes (); # bytes::length
use HTTP::Date qw(time2str);
use Digest::SHA ();
use File::Spec ();
use IO::Compress::Gzip qw(gzip);
*try_cat = \&PublicInbox::Inbox::try_cat;
our $json;
for my $mod (qw(JSON::MaybeXS JSON JSON::PP)) {
	eval "require $mod" or next;
	# ->ascii encodes non-ASCII to "\uXXXX"
	$json = $mod->new->ascii(1) and last;
}

sub list_all_i {
	my ($ibx, $arg) = @_;
	my ($list, $hide_key) = @$arg;
	push @$list, $ibx unless $ibx->{-hide}->{$hide_key};
}

sub list_all ($$$) {
	my ($self, $env, $hide_key) = @_;
	my $list = [];
	$self->{pi_config}->each_inbox(\&list_all_i, [ $list, $hide_key ]);
	$list;
}

sub list_match_domain_i {
	my ($ibx, $arg) = @_;
	my ($list, $hide_key, $re) = @$arg;
	if (!$ibx->{-hide}->{$hide_key} && grep($re, @{$ibx->{url}})) {
		push @$list, $ibx;
	}
}

sub list_match_domain ($$$) {
	my ($self, $env, $hide_key) = @_;
	my $list = [];
	my $host = $env->{HTTP_HOST} // $env->{SERVER_NAME};
	$host =~ s/:[0-9]+\z//;
	my $arg = [ $list, $hide_key,
		qr!\A(?:https?:)?//\Q$host\E(?::[0-9]+)?/!i ];
	$self->{pi_config}->each_inbox(\&list_match_domain_i, $arg);
	$list;
}

sub list_404 ($$) { [] }

# TODO: +cgit
my %VALID = (
	all => *list_all,
	'match=domain' => *list_match_domain,
	404 => *list_404,
);

sub set_cb ($$$) {
	my ($pi_config, $k, $default) = @_;
	my $v = $pi_config->{lc $k} // $default;
	$VALID{$v} || do {
		warn <<"";
`$v' is not a valid value for `$k'
$k be one of `all', `match=domain', or `404'

		$VALID{$default};
	};
}

sub new {
	my ($class, $www) = @_;
	my $pi_config = $www->{pi_config};
	bless {
		pi_config => $pi_config,
		style => $www->style("\0"),
		www_cb => set_cb($pi_config, 'publicInbox.wwwListing', 404),
		manifest_cb => set_cb($pi_config, 'publicInbox.grokManifest',
					'match=domain'),
	}, $class;
}

sub ibx_entry {
	my ($mtime, $ibx, $env) = @_;
	my $ts = PublicInbox::View::fmt_ts($mtime);
	my $url = prurl($env, $ibx->{url});
	my $tmp = <<"";
* $ts - $url
  ${\$ibx->description}

	if (defined(my $info_url = $ibx->{infourl})) {
		$tmp .= '  ' . prurl($env, $info_url) . "\n";
	}
	$tmp;
}

sub html ($$) {
	my ($env, $list) = @_;
	my $title = 'public-inbox';
	my $out = '';
	my $code = 404;
	if (@$list) {
		$title .= ' - listing';
		$code = 200;

		# Schwartzian transform since Inbox->modified is expensive
		@$list = sort {
			$b->[0] <=> $a->[0]
		} map { [ $_->modified, $_ ] } @$list;

		my $tmp = join("\n", map { ibx_entry(@$_, $env) } @$list);
		my $l = PublicInbox::Linkify->new;
		$out = '<pre>'.$l->to_html($tmp).'</pre><hr>';
	}
	$out = "<html><head><title>$title</title></head><body>" . $out;
	$out .= '<pre>'. PublicInbox::WwwStream::code_footer($env) .
		'</pre></body></html>';

	my $h = [ 'Content-Type', 'text/html; charset=UTF-8' ];
	[ $code, $h, [ $out ] ];
}

sub fingerprint ($) {
	my ($git) = @_;
	# TODO: convert to qspawn for fairness when there's
	# thousands of repos
	my ($fh, $pid) = $git->popen('show-ref');
	my $dig = Digest::SHA->new(1);
	while (read($fh, my $buf, 65536)) {
		$dig->add($buf);
	}
	close $fh;
	waitpid($pid, 0);
	return if $?; # empty, uninitialized git repo
	$dig->hexdigest;
}

sub manifest_add ($$;$$) {
	my ($manifest, $ibx, $epoch, $default_desc) = @_;
	my $url_path = "/$ibx->{name}";
	my $git_dir = $ibx->{inboxdir};
	if (defined $epoch) {
		$git_dir .= "/git/$epoch.git";
		$url_path .= "/git/$epoch.git";
	}
	return unless -d $git_dir;
	my $git = PublicInbox::Git->new($git_dir);
	my $fingerprint = fingerprint($git) or return; # no empty repos

	chomp(my $owner = $git->qx('config', 'gitweb.owner'));
	chomp(my $desc = try_cat("$git_dir/description"));
	$owner = undef if $owner eq '';
	$desc = 'Unnamed repository' if $desc eq '';

	# templates/hooks--update.sample and git-multimail in git.git
	# only match "Unnamed repository", not the full contents of
	# templates/this--description in git.git
	if ($desc =~ /\AUnnamed repository/) {
		$desc = "$default_desc [epoch $epoch]" if defined($epoch);
	}

	my $reference;
	chomp(my $alt = try_cat("$git_dir/objects/info/alternates"));
	if ($alt) {
		# n.b.: GitPython doesn't seem to handle comments or C-quoted
		# strings like native git does; and we don't for now, either.
		my @alt = split(/\n+/, $alt);

		# grokmirror only supports 1 alternate for "reference",
		if (scalar(@alt) == 1) {
			my $objdir = "$git_dir/objects";
			$reference = File::Spec->rel2abs($alt[0], $objdir);
			$reference =~ s!/[^/]+/?\z!!; # basename
		}
	}
	$manifest->{-abs2urlpath}->{$git_dir} = $url_path;
	my $modified = $git->modified;
	if ($modified > $manifest->{-mtime}) {
		$manifest->{-mtime} = $modified;
	}
	$manifest->{$url_path} = {
		owner => $owner,
		reference => $reference,
		description => $desc,
		modified => $modified,
		fingerprint => $fingerprint,
	};
}

# manifest.js.gz
sub js ($$) {
	my ($env, $list) = @_;
	# $json won't be defined if IO::Compress::Gzip is missing
	$json or return [ 404, [], [] ];

	my $manifest = { -abs2urlpath => {}, -mtime => 0 };
	for my $ibx (@$list) {
		if (defined(my $max = $ibx->max_git_epoch)) {
			my $desc = $ibx->description;
			for my $epoch (0..$max) {
				manifest_add($manifest, $ibx, $epoch, $desc);
			}
		} else {
			manifest_add($manifest, $ibx);
		}
	}
	my $abs2urlpath = delete $manifest->{-abs2urlpath};
	my $mtime = delete $manifest->{-mtime};
	while (my ($url_path, $repo) = each %$manifest) {
		defined(my $abs = $repo->{reference}) or next;
		$repo->{reference} = $abs2urlpath->{$abs};
	}
	my $out;
	gzip(\($json->encode($manifest)) => \$out);
	$manifest = undef;
	[ 200, [ qw(Content-Type application/gzip),
		 'Last-Modified', time2str($mtime),
		 'Content-Length', bytes::length($out) ], [ $out ] ];
}

# not really a stand-alone PSGI app, but maybe it could be...
sub call {
	my ($self, $env) = @_;

	if ($env->{PATH_INFO} eq '/manifest.js.gz') {
		# grokmirror uses relative paths, so it's domain-dependent
		my $list = $self->{manifest_cb}->($self, $env, 'manifest');
		js($env, $list);
	} else { # /
		my $list = $self->{www_cb}->($self, $env, 'www');
		html($env, $list);
	}
}

1;
