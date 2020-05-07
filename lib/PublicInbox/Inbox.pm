# Copyright (C) 2016-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Represents a public-inbox (which may have multiple mailing addresses)
package PublicInbox::Inbox;
use strict;
use warnings;
use PublicInbox::Git;
use PublicInbox::MID qw(mid2path);
use PublicInbox::Eml;

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
	# no need to require DS, here, if it were enabled another
	# module would've require'd it, already
	eval { PublicInbox::DS::in_loop() } or return 0;

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
	$cleanup_timer ||= PublicInbox::DS::later(*cleanup_task);
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
	$self->{$lkey} ||= do {
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
	my $dir = $opts->{inboxdir};
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

sub version { $_[0]->{version} // 1 }

sub git_epoch {
	my ($self, $epoch) = @_;
	$self->version == 2 or return;
	$self->{"$epoch.git"} ||= do {
		my $git_dir = "$self->{inboxdir}/git/$epoch.git";
		my $g = PublicInbox::Git->new($git_dir);
		$g->{-httpbackend_limiter} = $self->{-httpbackend_limiter};
		# no cleanup needed, we never cat-file off this, only clone
		$g;
	};
}

sub git {
	my ($self) = @_;
	$self->{git} ||= do {
		my $git_dir = $self->{inboxdir};
		$git_dir .= '/all.git' if $self->version == 2;
		my $g = PublicInbox::Git->new($git_dir);
		$g->{-httpbackend_limiter} = $self->{-httpbackend_limiter};
		_cleanup_later($self);
		$g;
	};
}

sub max_git_epoch {
	my ($self) = @_;
	return if $self->version < 2;
	my $cur = $self->{-max_git_epoch};
	my $changed = git($self)->alternates_changed;
	if (!defined($cur) || $changed) {
		$self->git->cleanup if $changed;
		my $gits = "$self->{inboxdir}/git";
		if (opendir my $dh, $gits) {
			my $max = -1;
			while (defined(my $git_dir = readdir($dh))) {
				$git_dir =~ m!\A([0-9]+)\.git\z! or next;
				$max = $1 if $1 > $max;
			}
			$cur = $self->{-max_git_epoch} = $max if $max >= 0;
		} else {
			warn "opendir $gits failed: $!\n";
		}
	}
	$cur;
}

sub mm {
	my ($self) = @_;
	$self->{mm} ||= eval {
		require PublicInbox::Msgmap;
		_cleanup_later($self);
		my $dir = $self->{inboxdir};
		if ($self->version >= 2) {
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
	($self->{description} //= do {
		my $desc = try_cat("$self->{inboxdir}/description");
		local $/ = "\n";
		chomp $desc;
		$desc =~ s/\s+/ /smg;
		$desc eq '' ? undef : $desc;
	}) // '($INBOX_DIR/description missing)';
}

sub cloneurl {
	my ($self) = @_;
	($self->{cloneurl} //= do {
		my $s = try_cat("$self->{inboxdir}/cloneurl");
		my @urls = split(/\s+/s, $s);
		scalar(@urls) ? \@urls : undef
	}) // [];
}

sub base_url {
	my ($self, $env) = @_; # env - PSGI env
	if ($env) {
		my $url = PublicInbox::Git::host_prefix_url($env, '');
		# for mount in Plack::Builder
		$url .= '/' if $url !~ m!/\z!;
		return $url .= $self->{name} . '/';
	}
	# called from a non-PSGI environment (e.g. NNTP/POP3):
	$self->{-base_url} ||= do {
		my $url = $self->{url}->[0] or return undef;
		# expand protocol-relative URLs to HTTPS if we're
		# not inside a web server
		$url = "https:$url" if $url =~ m!\A//!;
		$url .= '/' if $url !~ m!/\z!;
		$url;
	};
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

			# List::Util::uniq requires Perl 5.26+, maybe we
			# can use it by 2030 or so
			my %seen;
			@urls = grep { !$seen{$_}++ } (@urls, @m);
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

# for v1 users w/o SQLite only
sub msg_by_path ($$;$) {
	my ($self, $path, $ref) = @_;
	git($self)->cat_file('HEAD:'.$path, $ref);
}

sub msg_by_smsg ($$;$) {
	my ($self, $smsg, $ref) = @_;

	# ghosts may have undef smsg (from SearchThread.node) or
	# no {blob} field
	return unless defined $smsg;
	defined(my $blob = $smsg->{blob}) or return;

	git($self)->cat_file($blob, $ref);
}

sub smsg_mime {
	my ($self, $smsg, $ref) = @_;
	if (my $s = msg_by_smsg($self, $smsg, $ref)) {
		$smsg->{mime} = PublicInbox::Eml->new($s);
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
	PublicInbox::Smsg::psgi_cull($smsg);
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

# returns prefix => pathname mapping
# (pathname is NOT public, but prefix is used for Xapian queries)
sub altid_map ($) {
	my ($self) = @_;
	$self->{-altid_map} //= eval {
		require PublicInbox::AltId;
		my $altid = $self->{altid} or return {};
		my %h = map {;
			my $x = PublicInbox::AltId->new($self, $_);
			"$x->{prefix}" => $x->{filename}
		} @$altid;
		\%h;
	} // {};
}

1;
