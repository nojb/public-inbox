# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
package PublicInbox::ManifestJsGz;
use strict;
use v5.10.1;
use Digest::SHA ();
use File::Spec ();
use bytes (); # length
use PublicInbox::Inbox;
use PublicInbox::Git;
use IO::Compress::Gzip qw(gzip);
use HTTP::Date qw(time2str);
*try_cat = \&PublicInbox::Inbox::try_cat;

our $json;
for my $mod (qw(JSON::MaybeXS JSON JSON::PP)) {
	eval "require $mod" or next;
	# ->ascii encodes non-ASCII to "\uXXXX"
	$json = $mod->new->ascii(1) and last;
}

sub response {
	my ($env, $list) = @_;
	$json or return [ 404, [], [] ];
	my $self = bless {
		-abs2urlpath => {},
		-mtime => 0,
		manifest => {},
		-list => $list,
		psgi_env => $env,
	}, __PACKAGE__;

	# PSGI server will call this immediately and give us a callback (-wcb)
	sub {
		$self->{-wcb} = $_[0]; # HTTP write callback
		iterate_start($self);
	};
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
	my ($self, $ibx, $epoch, $default_desc) = @_;
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
	$self->{-abs2urlpath}->{$git_dir} = $url_path;
	my $modified = $git->modified;
	if ($modified > $self->{-mtime}) {
		$self->{-mtime} = $modified;
	}
	$self->{manifest}->{$url_path} = {
		owner => $owner,
		reference => $reference,
		description => $desc,
		modified => $modified,
		fingerprint => $fingerprint,
	};
}

sub iterate_start {
	my ($self) = @_;
	if (my $async = $self->{psgi_env}->{'pi-httpd.async'}) {
		# PublicInbox::HTTPD::Async->new
		$async->(undef, undef, $self);
	} else {
		event_step($self) while $self->{-wcb};
	}
}

sub event_step {
	my ($self) = @_;
	while (my $ibx = shift(@{$self->{-list}})) {
		eval {
			if (defined(my $max = $ibx->max_git_epoch)) {
				my $desc = $ibx->description;
				for my $epoch (0..$max) {
					manifest_add($self, $ibx, $epoch, $desc)
				}
			} else {
				manifest_add($self, $ibx);
			}
		};
		warn "E: $@" if $@;
		if (my $async = $self->{psgi_env}->{'pi-httpd.async'}) {
			# PublicInbox::HTTPD::Async->new
			$async->(undef, undef, $self);
		}
		return; # more steps needed
	}
	my $abs2urlpath = delete $self->{-abs2urlpath};
	my $wcb = delete $self->{-wcb};
	my $manifest = delete $self->{manifest};
	while (my ($url_path, $repo) = each %$manifest) {
		defined(my $abs = $repo->{reference}) or next;
		$repo->{reference} = $abs2urlpath->{$abs};
	}
	$manifest = $json->encode($manifest);
	gzip(\$manifest => \(my $out));
	$wcb->([ 200, [ qw(Content-Type application/gzip),
		 'Last-Modified', time2str($self->{-mtime}),
		 'Content-Length', bytes::length($out) ], [ $out ] ]);
}

1;
