# Copyright (C) 2016-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Represents a public-inbox (which may have multiple mailing addresses)
package PublicInbox::Inbox;
use strict;
use warnings;
use PublicInbox::Git;
use PublicInbox::MID qw(mid2path);
use PublicInbox::MIME;

# Long-running "git-cat-file --batch" processes won't notice
# unlinked packs, so we need to restart those processes occasionally.
# Xapian and SQLite file handles are mostly stable, but sometimes an
# admin will attempt to replace them atomically after compact/vacuum
# and we need to be prepared for that.
my $cleanup_timer;
my $cleanup_avail = -1; # 0, or 1
my $have_devel_peek;
my $CLEANUP = {}; # string(inbox) -> inbox
sub cleanup_task () {
	$cleanup_timer = undef;
	my $next = {};
	for my $ibx (values %$CLEANUP) {
		my $again;
		if ($have_devel_peek) {
			foreach my $f (qw(mm search over)) {
				# we bump refcnt by assigning tmp, here:
				my $tmp = $ibx->{$f} or next;
				next if Devel::Peek::SvREFCNT($tmp) > 2;
				delete $ibx->{$f};
				# refcnt is zero when tmp is out-of-scope
			}
		}
		if (my $git = $ibx->{git}) {
			$again = $git->cleanup;
		}
		if (my $gits = $ibx->{-repo_objs}) {
			foreach my $git (@$gits) {
				$again = 1 if $git->cleanup;
			}
		}
		if ($have_devel_peek) {
			$again ||= !!($ibx->{over} || $ibx->{mm} ||
			              $ibx->{search});
		}
		$next->{"$ibx"} = $ibx if $again;
	}
	$CLEANUP = $next;
}

sub cleanup_possible () {
	# no need to require EvCleanup, here, if it were enabled another
	# module would've require'd it, already
	eval { PublicInbox::EvCleanup::enabled() } or return 0;

	eval {
		require Devel::Peek; # needs separate package in Fedora
		$have_devel_peek = 1;
	};
	1;
}

sub _cleanup_later ($) {
	my ($self) = @_;
	$cleanup_avail = cleanup_possible() if $cleanup_avail < 0;
	return if $cleanup_avail != 1;
	$cleanup_timer ||= PublicInbox::EvCleanup::later(*cleanup_task);
	$CLEANUP->{"$self"} = $self;
}

sub _set_uint ($$$) {
	my ($opts, $field, $default) = @_;
	my $val = $opts->{$field};
	if (defined $val) {
		$val = $val->[-1] if ref($val) eq 'ARRAY';
		$val = undef if $val !~ /\A[0-9]+\z/;
	}
	$opts->{$field} = $val || $default;
}

sub _set_limiter ($$$) {
	my ($self, $pi_config, $pfx) = @_;
	my $lkey = "-${pfx}_limiter";
	$self->{$lkey} ||= eval {
		# full key is: publicinbox.$NAME.httpbackendmax
		my $mkey = $pfx.'max';
		my $val = $self->{$mkey} or return;
		my $lim;
		if ($val =~ /\A[0-9]+\z/) {
			require PublicInbox::Qspawn;
			$lim = PublicInbox::Qspawn::Limiter->new($val);
		} elsif ($val =~ /\A[a-z][a-z0-9]*\z/) {
			$lim = $pi_config->limiter($val);
			warn "$mkey limiter=$val not found\n" if !$lim;
		} else {
			warn "$mkey limiter=$val not understood\n";
		}
		$lim;
	}
}

sub new {
	my ($class, $opts) = @_;
	my $v = $opts->{address} ||= 'public-inbox@example.com';
	my $p = $opts->{-primary_address} = ref($v) eq 'ARRAY' ? $v->[0] : $v;
	$opts->{domain} = ($p =~ /\@(\S+)\z/) ? $1 : 'localhost';
	my $pi_config = delete $opts->{-pi_config};
	_set_limiter($opts, $pi_config, 'httpbackend');
	_set_uint($opts, 'feedmax', 25);
	$opts->{nntpserver} ||= $pi_config->{'publicinbox.nntpserver'};
	my $dir = $opts->{mainrepo};
	if (defined $dir && -f "$dir/inbox.lock") {
		$opts->{version} = 2;
	}

	# allow any combination of multi-line or comma-delimited hide entries
	my $hide = {};
	if (defined(my $h = $opts->{hide})) {
		foreach my $v (@$h) {
			$hide->{$_} = 1 foreach (split(/\s*,\s*/, $v));
		}
		$opts->{-hide} = $hide;
	}
	bless $opts, $class;
}

sub git_part {
	my ($self, $part) = @_;
	($self->{version} || 1) == 2 or return;
	$self->{"$part.git"} ||= eval {
		my $git_dir = "$self->{mainrepo}/git/$part.git";
		my $g = PublicInbox::Git->new($git_dir);
		$g->{-httpbackend_limiter} = $self->{-httpbackend_limiter};
		# no cleanup needed, we never cat-file off this, only clone
		$g;
	};
}

sub git {
	my ($self) = @_;
	$self->{git} ||= eval {
		my $git_dir = $self->{mainrepo};
		$git_dir .= '/all.git' if (($self->{version} || 1) == 2);
		my $g = PublicInbox::Git->new($git_dir);
		$g->{-httpbackend_limiter} = $self->{-httpbackend_limiter};
		_cleanup_later($self);
		$g;
	};
}

sub max_git_part {
	my ($self) = @_;
	my $v = $self->{version};
	return unless defined($v) && $v == 2;
	my $part = $self->{-max_git_part};
	my $changed = git($self)->alternates_changed;
	if (!defined($part) || $changed) {
		$self->git->cleanup if $changed;
		my $gits = "$self->{mainrepo}/git";
		if (opendir my $dh, $gits) {
			my $max = -1;
			while (defined(my $git_dir = readdir($dh))) {
				$git_dir =~ m!\A([0-9]+)\.git\z! or next;
				$max = $1 if $1 > $max;
			}
			$part = $self->{-max_git_part} = $max if $max >= 0;
		} else {
			warn "opendir $gits failed: $!\n";
		}
	}
	$part;
}

sub mm {
	my ($self) = @_;
	$self->{mm} ||= eval {
		require PublicInbox::Msgmap;
		_cleanup_later($self);
		my $dir = $self->{mainrepo};
		if (($self->{version} || 1) >= 2) {
			PublicInbox::Msgmap->new_file("$dir/msgmap.sqlite3");
		} else {
			PublicInbox::Msgmap->new($dir);
		}
	};
}

sub search ($;$) {
	my ($self, $over_only) = @_;
	my $srch = $self->{search} ||= eval {
		_cleanup_later($self);
		require PublicInbox::Search;
		PublicInbox::Search->new($self);
	};
	($over_only || eval { $srch->xdb }) ? $srch : undef;
}

sub over ($) {
	my ($self) = @_;
	my $srch = search($self, 1) or return;
	$self->{over} ||= eval {
		my $over = $srch->{over_ro};
		$over->dbh_new; # may fail
		$over;
	}
}

sub try_cat {
	my ($path) = @_;
	my $rv = '';
	if (open(my $fh, '<', $path)) {
		local $/;
		$rv = <$fh>;
	}
	$rv;
}

sub description {
	my ($self) = @_;
	my $desc = $self->{description};
	return $desc if defined $desc;
	$desc = try_cat("$self->{mainrepo}/description");
	local $/ = "\n";
	chomp $desc;
	$desc =~ s/\s+/ /smg;
	$desc = '($INBOX_DIR/description missing)' if $desc eq '';
	$self->{description} = $desc;
}

sub cloneurl {
	my ($self) = @_;
	my $url = $self->{cloneurl};
	return $url if $url;
	$url = try_cat("$self->{mainrepo}/cloneurl");
	my @url = split(/\s+/s, $url);
	local $/ = "\n";
	chomp @url;
	$self->{cloneurl} = \@url;
}

sub base_url {
	my ($self, $env) = @_;
	my $scheme;
	if ($env && ($scheme = $env->{'psgi.url_scheme'})) { # PSGI env
		my $host_port = $env->{HTTP_HOST} ||
			"$env->{SERVER_NAME}:$env->{SERVER_PORT}";
		my $url = "$scheme://$host_port". ($env->{SCRIPT_NAME} || '/');
		# for mount in Plack::Builder
		$url .= '/' if $url !~ m!/\z!;
		$url .= $self->{name} . '/';
	} else {
		# either called from a non-PSGI environment (e.g. NNTP/POP3)
		$self->{-base_url} ||= do {
			my $url = $self->{url} or return undef;
			# expand protocol-relative URLs to HTTPS if we're
			# not inside a web server
			$url = "https:$url" if $url =~ m!\A//!;
			$url .= '/' if $url !~ m!/\z!;
			$url;
		};
	}
}

sub nntp_url {
	my ($self) = @_;
	$self->{-nntp_url} ||= do {
		# no checking for nntp_usable here, we can point entirely
		# to non-local servers or users run by a different user
		my $ns = $self->{nntpserver};
		my $group = $self->{newsgroup};
		my @urls;
		if ($ns && $group) {
			$ns = [ $ns ] if ref($ns) ne 'ARRAY';
			@urls = map {
				my $u = m!\Anntps?://! ? $_ : "nntp://$_";
				$u .= '/' if $u !~ m!/\z!;
				$u.$group;
			} @$ns;
		}

		my $mirrors = $self->{nntpmirror};
		if ($mirrors) {
			my @m;
			foreach (@$mirrors) {
				my $u = m!\Anntps?://! ? $_ : "nntp://$_";
				if ($u =~ m!\Anntps?://[^/]+/?\z!) {
					if ($group) {
						$u .= '/' if $u !~ m!/\z!;
						$u .= $group;
					} else {
						warn
"publicinbox.$self->{name}.nntpmirror=$_ missing newsgroup name\n";
					}
				}
				# else: allow full URLs like:
				# nntp://news.example.com/alt.example
				push @m, $u;
			}
			my %seen = map { $_ => 1 } @urls;
			foreach my $u (@m) {
				next if $seen{$u};
				$seen{$u} = 1;
				push @urls, $u;
			}
		}
		\@urls;
	};
}

sub nntp_usable {
	my ($self) = @_;
	my $ret = mm($self) && over($self);
	$self->{mm} = $self->{over} = $self->{search} = undef;
	$ret;
}

sub msg_by_path ($$;$) {
	my ($self, $path, $ref) = @_;
	# TODO: allow other refs:
	my $str = git($self)->cat_file('HEAD:'.$path, $ref);
	$$str =~ s/\A[\r\n]*From [^\r\n]*\r?\n//s if $str;
	$str;
}

sub msg_by_smsg ($$;$) {
	my ($self, $smsg, $ref) = @_;

	# ghosts may have undef smsg (from SearchThread.node) or
	# no {blob} field
	return unless defined $smsg;
	defined(my $blob = $smsg->{blob}) or return;

	my $str = git($self)->cat_file($blob, $ref);
	$$str =~ s/\A[\r\n]*From [^\r\n]*\r?\n//s if $str;
	$str;
}

sub smsg_mime {
	my ($self, $smsg, $ref) = @_;
	if (my $s = msg_by_smsg($self, $smsg, $ref)) {
		$smsg->{mime} = PublicInbox::MIME->new($s);
		return $smsg;
	}
}

sub mid2num($$) {
	my ($self, $mid) = @_;
	my $mm = mm($self) or return;
	$mm->num_for($mid);
}

sub smsg_by_mid ($$) {
	my ($self, $mid) = @_;
	my $over = over($self) or return;
	# favor the Message-ID we used for the NNTP article number:
	defined(my $num = mid2num($self, $mid)) or return;
	my $smsg = $over->get_art($num) or return;
	PublicInbox::SearchMsg::psgi_cull($smsg);
}

sub msg_by_mid ($$;$) {
	my ($self, $mid, $ref) = @_;

	over($self) or
		return msg_by_path($self, mid2path($mid), $ref);

	my $smsg = smsg_by_mid($self, $mid);
	$smsg ? msg_by_smsg($self, $smsg, $ref) : undef;
}

sub recent {
	my ($self, $opts, $after, $before) = @_;
	over($self)->recent($opts, $after, $before);
}

sub modified {
	my ($self) = @_;
	if (my $over = over($self)) {
		my $msgs = $over->recent({limit => 1});
		if (my $smsg = $msgs->[0]) {
			return $smsg->{ts};
		}
		return time;
	}
	git($self)->modified; # v1
}

1;
