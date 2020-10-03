# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# generates manifest.js.gz for grokmirror(1)
package PublicInbox::ManifestJsGz;
use strict;
use v5.10.1;
use parent qw(PublicInbox::WwwListing);
use Digest::SHA ();
use File::Spec ();
use bytes (); # length
use PublicInbox::Inbox;
use PublicInbox::Git;
use IO::Compress::Gzip qw(gzip);
use HTTP::Date qw(time2str);
*try_cat = \&PublicInbox::Inbox::try_cat;

our $json;
for my $mod (qw(Cpanel::JSON::XS JSON::MaybeXS JSON JSON::PP)) {
	eval "require $mod" or next;
	# ->ascii encodes non-ASCII to "\uXXXX"
	$json = $mod->new->ascii(1) and last;
}

# called by WwwListing
sub url_regexp {
	my ($ctx) = @_;
	# grokmirror uses relative paths, so it's domain-dependent
	# SUPER calls PublicInbox::WwwListing::url_regexp
	$ctx->SUPER::url_regexp('publicInbox.grokManifest', 'match=domain');
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
	my ($ctx, $ibx, $epoch, $default_desc) = @_;
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
	utf8::decode($owner);
	utf8::decode($desc);
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
	$ctx->{-abs2urlpath}->{$git_dir} = $url_path;
	my $modified = $git->modified;
	if ($modified > ($ctx->{-mtime} // 0)) {
		$ctx->{-mtime} = $modified;
	}
	$ctx->{manifest}->{$url_path} = {
		owner => $owner,
		reference => $reference,
		description => $desc,
		modified => $modified,
		fingerprint => $fingerprint,
	};
}

sub ibx_entry {
	my ($ctx, $ibx) = @_;
	eval {
		if (defined(my $max = $ibx->max_git_epoch)) {
			my $desc = $ibx->description;
			for my $epoch (0..$max) {
				manifest_add($ctx, $ibx, $epoch, $desc);
			}
		} else {
			manifest_add($ctx, $ibx);
		}
	};
	warn "E: $@" if $@;
}

sub hide_key { 'manifest' }

# overrides WwwListing->psgi_triple
sub psgi_triple {
	my ($ctx) = @_;
	my $abs2urlpath = delete($ctx->{-abs2urlpath}) // {};
	my $manifest = delete($ctx->{manifest}) // {};
	while (my ($url_path, $repo) = each %$manifest) {
		defined(my $abs = $repo->{reference}) or next;
		$repo->{reference} = $abs2urlpath->{$abs};
	}
	$manifest = $json->encode($manifest);
	gzip(\$manifest => \(my $out));
	[ 200, [ qw(Content-Type application/gzip),
		 'Last-Modified', time2str($ctx->{-mtime}),
		 'Content-Length', bytes::length($out) ], [ $out ] ]
}

1;
