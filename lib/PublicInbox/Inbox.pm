# Copyright (C) 2016-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Represents a public-inbox (which may have multiple mailing addresses)
package PublicInbox::Inbox;
use strict;
use PublicInbox::Git;
use PublicInbox::MID qw(mid2path);
use PublicInbox::Eml;
use List::Util qw(max);
use Carp qw(croak);

# returns true if further checking is required
sub check_inodes ($) {
	for (qw(over mm)) { $_[0]->{$_}->check_inodes if $_[0]->{$_} }
}

sub do_cleanup {
	my ($ibx) = @_;
	my $live;
	if (defined $ibx->{git}) {
		$live = $ibx->isa(__PACKAGE__) ? $ibx->{git}->cleanup(1)
					: $ibx->{git}->cleanup_if_unlinked;
		delete($ibx->{git}) unless $live;
	}
	if ($live) {
		check_inodes($ibx);
	} else {
		delete(@$ibx{qw(over mm description cloneurl
				-imap_url -nntp_url)});
	}
	my $srch = $ibx->{search} // $ibx;
	delete @$srch{qw(xdb qp)};
	for my $git (@{$ibx->{-repo_objs} // []}) {
		$live = 1 if $git->cleanup(1);
	}
	PublicInbox::DS::add_uniq_timer($ibx+0, 5, \&do_cleanup, $ibx) if $live;
}

sub _cleanup_later ($) {
	# no need to require DS, here, if it were enabled another
	# module would've require'd it, already
	eval { PublicInbox::DS::in_loop() } and
		PublicInbox::DS::add_uniq_timer($_[0]+0, 30, \&do_cleanup, @_)
}

sub _set_limiter ($$$) {
	my ($self, $pi_cfg, $pfx) = @_;
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
			$lim = $pi_cfg->limiter($val);
			warn "$mkey limiter=$val not found\n" if !$lim;
		} else {
			warn "$mkey limiter=$val not understood\n";
		}
		$lim;
	}
}

sub new {
	my ($class, $opts) = @_;
	my $v = $opts->{address} ||= [ 'public-inbox@example.com' ];
	my $p = $opts->{-primary_address} = ref($v) eq 'ARRAY' ? $v->[0] : $v;
	$opts->{domain} = ($p =~ /\@(\S+)\z/) ? $1 : 'localhost';
	my $pi_cfg = delete $opts->{-pi_cfg};
	_set_limiter($opts, $pi_cfg, 'httpbackend');
	my $fmax = $opts->{feedmax};
	if (defined($fmax) && $fmax =~ /\A[0-9]+\z/) {
		$opts->{feedmax} += 0;
	} else {
		delete $opts->{feedmax};
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

sub version {
	$_[0]->{version} //= -f "$_[0]->{inboxdir}/inbox.lock" ? 2 : 1
}

sub git_epoch {
	my ($self, $epoch) = @_; # v2-only, callers always supply $epoch
	$self->{"$epoch.git"} //= do {
		my $git_dir = "$self->{inboxdir}/git/$epoch.git";
		return unless -d $git_dir;
		my $g = PublicInbox::Git->new($git_dir);
		my $lim = $self->{-httpbackend_limiter};
		$g->{-httpbackend_limiter} = $lim if $lim;
		# caller must manually cleanup when done
		$g;
	};
}

sub git {
	my ($self) = @_;
	$self->{git} //= do {
		my $git_dir = $self->{inboxdir};
		$git_dir .= '/all.git' if $self->version == 2;
		my $g = PublicInbox::Git->new($git_dir);
		my $lim = $self->{-httpbackend_limiter};
		$g->{-httpbackend_limiter} = $lim if $lim;
		_cleanup_later($self);
		$g;
	};
}

sub max_git_epoch {
	my ($self) = @_;
	return if $self->version < 2;
	my $cur = $self->{-max_git_epoch};
	my $changed;
	if (!defined($cur) || ($changed = git($self)->alternates_changed)) {
		$self->{git}->cleanup if $changed;
		my $gits = "$self->{inboxdir}/git";
		if (opendir my $dh, $gits) {
			my $max = max(map {
				substr($_, 0, -4) + 0; # drop ".git" suffix
			} grep(/\A[0-9]+\.git\z/, readdir($dh))) // return;
			$cur = $self->{-max_git_epoch} = $max;
		}
	}
	$cur;
}

sub mm_file {
	my ($self) = @_;
	my $d = $self->{inboxdir};
	($self->version >= 2 ? $d : "$d/public-inbox").'/msgmap.sqlite3';
}

sub mm {
	my ($self, $req) = @_;
	$self->{mm} //= eval {
		require PublicInbox::Msgmap;
		_cleanup_later($self);
		PublicInbox::Msgmap->new_file(mm_file($self));
	} // ($req ? croak("E: $@") : undef);
}

sub search {
	my ($self) = @_;
	$self->{search} // eval {
		_cleanup_later($self);
		require PublicInbox::Search;
		my $srch = PublicInbox::Search->new($self);
		(eval { $srch->xdb }) ? ($self->{search} = $srch) : undef;
	};
}

# isrch is preferred for read-only interfaces if available since it
# reduces kernel cache and FD overhead
sub isrch { $_[0]->{isrch} // search($_[0]) }

sub over {
	my ($self, $req) = @_;
	$self->{over} // eval {
		my $srch = $self->{search} // do {
			require PublicInbox::Search;
			PublicInbox::Search->new($self);
		};
		_cleanup_later($self);
		my $over = PublicInbox::Over->new("$srch->{xpfx}/over.sqlite3");
		$over->dbh; # may fail
		$self->{over} = $over;
	} // ($req ? croak("E: $@") : undef);
}

sub try_cat {
	my ($path) = @_;
	open(my $fh, '<', $path) or return '';
	local $/;
	<$fh> // '';
}

sub cat_desc ($) {
	my $desc = try_cat($_[0]);
	local $/ = "\n";
	chomp $desc;
	utf8::decode($desc);
	$desc =~ s/\s+/ /smg;
	$desc eq '' ? undef : $desc;
}

sub description {
	my ($self) = @_;
	($self->{description} //= cat_desc("$self->{inboxdir}/description")) //
		'($INBOX_DIR/description missing)';
}

sub cloneurl {
	my ($self) = @_;
	$self->{cloneurl} // do {
		my $s = try_cat("$self->{inboxdir}/cloneurl");
		my @urls = split(/\s+/s, $s);
		scalar(@urls) ? ($self->{cloneurl} = \@urls) : undef;
	} // [];
}

sub base_url {
	my ($self, $env) = @_; # env - PSGI env
	if ($env && $env->{'psgi.url_scheme'}) {
		my $url = PublicInbox::Git::host_prefix_url($env, '');
		# for mount in Plack::Builder
		$url .= '/' if $url !~ m!/\z!;
		return $url .= $self->{name} . '/';
	}
	# called from a non-PSGI environment (e.g. NNTP/POP3):
	my $url = $self->{url} // return undef;
	$url = $url->[0] // return undef;
	# expand protocol-relative URLs to HTTPS if we're
	# not inside a web server
	substr($url, 0, 0, 'https:') if substr($url, 0, 2) eq '//';
	$url .= '/' if substr($url, -1, 1) ne '/';
	$url;
}

sub _x_url ($$$) {
	my ($self, $x, $ctx) = @_; # $x is "nntp" or "imap"
	# no checking for nntp_usable here, we can point entirely
	# to non-local servers or users run by a different user
	my $ns = $self->{"${x}server"} //
	       $ctx->{www}->{pi_cfg}->get_all("publicinbox.${x}server");
	my $group = $self->{newsgroup};
	my @urls;
	if ($ns && $group) {
		@urls = map {
			my $u = m!\A${x}s?://! ? $_ : "$x://$_";
			$u .= '/' if $u !~ m!/\z!;
			$u.$group;
		} @$ns;
	}
	if (my $mirrors = $self->{"${x}mirror"}) {
		my @m;
		for (@$mirrors) {
			my $u = m!\A${x}s?://! ? $_ : "$x://$_";
			if ($u =~ m!\A${x}s?://[^/]+/?\z!) {
				if ($group) {
					$u .= '/' if $u !~ m!/\z!;
					$u .= $group;
				} else { # n.b. IMAP uses "newsgroup"
					warn <<EOM;
publicinbox.$self->{name}.${x}mirror=$_ missing newsgroup name
EOM
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
}

# my ($self, $ctx) = @_;
sub nntp_url { $_[0]->{-nntp_url} //= _x_url($_[0], 'nntp', $_[1]) }
sub imap_url { $_[0]->{-imap_url} //= _x_url($_[0], 'imap', $_[1]) }

sub nntp_usable {
	my ($self) = @_;
	my $ret = mm($self) && over($self);
	delete @$self{qw(mm over search)};
	$ret;
}

# for v1 users w/o SQLite only
sub msg_by_path ($$) {
	my ($self, $path) = @_;
	git($self)->cat_file('HEAD:'.$path);
}

sub msg_by_smsg ($$) {
	my ($self, $smsg) = @_;

	# ghosts may have undef smsg (from SearchThread.node) or
	# no {blob} field
	return unless defined $smsg;
	defined(my $blob = $smsg->{blob}) or return;

	$self->git->cat_file($blob);
}

sub smsg_eml {
	my ($self, $smsg) = @_;
	my $bref = msg_by_smsg($self, $smsg) or return;
	my $eml = PublicInbox::Eml->new($bref);
	$smsg->populate($eml) unless exists($smsg->{num}); # v1 w/o SQLite
	$eml;
}

sub smsg_by_mid ($$) {
	my ($self, $mid) = @_;
	my $over = $self->over or return;
	my $smsg;
	if (my $mm = $self->mm) {
		# favor the Message-ID we used for the NNTP article number:
		defined(my $num = $mm->num_for($mid)) or return;
		$smsg = $over->get_art($num);
	} else {
		my ($id, $prev);
		$smsg = $over->next_by_mid($mid, \$id, \$prev);
	}
	$smsg ? PublicInbox::Smsg::psgi_cull($smsg) : undef;
}

sub msg_by_mid ($$) {
	my ($self, $mid) = @_;
	my $smsg = smsg_by_mid($self, $mid);
	$smsg ? msg_by_smsg($self, $smsg) : msg_by_path($self, mid2path($mid));
}

sub recent {
	my ($self, $opts, $after, $before) = @_;
	$self->over->recent($opts, $after, $before);
}

sub modified {
	my ($self) = @_;
	if (my $over = $self->over) {
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
	eval {
		require PublicInbox::AltId;
		my $altid = $self->{altid} or return {};
		my %h = map {;
			my $x = PublicInbox::AltId->new($self, $_);
			"$x->{prefix}" => $x->{filename}
		} @$altid;
		\%h;
	} // {};
}

# $obj must respond to ->on_inbox_unlock, which takes Inbox ($self) as an arg
sub subscribe_unlock {
	my ($self, $ident, $obj) = @_;
	$self->{unlock_subs}->{$ident} = $obj;
}

sub unsubscribe_unlock {
	my ($self, $ident) = @_;
	delete $self->{unlock_subs}->{$ident};
}

# called by inotify
sub on_unlock {
	my ($self) = @_;
	check_inodes($self);
	my $subs = $self->{unlock_subs} or return;
	for my $obj (values %$subs) {
		eval { $obj->on_inbox_unlock($self) };
		warn "E: $@ ($self->{inboxdir})\n" if $@;
	}
}

sub uidvalidity { $_[0]->{uidvalidity} //= eval { $_[0]->mm->created_at } }

sub eidx_key { $_[0]->{newsgroup} // $_[0]->{inboxdir} }

sub mailboxid { # rfc 8474, 8620, 8621
	my ($self, $imap_slice) = @_;
	my $pfx = defined($imap_slice) ? $self->{newsgroup} : $self->{name};
	utf8::encode($pfx); # to octets
	# RFC 8620, 1.2 recommends not starting with dash or digits
	# "A good solution to these issues is to prefix every id with a single
	#  alphabetical character."
	'M'.join('', map { sprintf('%02x', ord) } split(//, $pfx)) .
		(defined($imap_slice) ? sprintf('-%x', $imap_slice) : '') .
		sprintf('-%x', uidvalidity($self) // 0)
}

1;
