# Copyright (C) 2014-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Used throughout the project for reading configuration
#
# Note: I hate camelCase; but git-config(1) uses it, but it's better
# than alllowercasewithoutunderscores, so use lc('configKey') where
# applicable for readability

package PublicInbox::Config;
use strict;
use warnings;
require PublicInbox::Inbox;
use PublicInbox::Spawn qw(popen_rd);

sub _array ($) { ref($_[0]) eq 'ARRAY' ? $_[0] : [ $_[0] ] }

# returns key-value pairs of config directives in a hash
# if keys may be multi-value, the value is an array ref containing all values
sub new {
	my ($class, $file) = @_;
	$file = default_file() unless defined($file);
	$file = ref $file ? $file : git_config_dump($file);
	my $self = bless $file, $class;

	# caches
	$self->{-by_addr} ||= {};
	$self->{-by_name} ||= {};
	$self->{-by_newsgroup} ||= {};
	$self->{-no_obfuscate} ||= {};
	$self->{-limiters} ||= {};
	$self->{-code_repos} ||= {}; # nick => PublicInbox::Git object
	$self->{-cgitrc_unparsed} = $self->{'publicinbox.cgitrc'};

	if (my $no = delete $self->{'publicinbox.noobfuscate'}) {
		$no = _array($no);
		my @domains;
		foreach my $n (@$no) {
			my @n = split(/\s+/, $n);
			foreach (@n) {
				if (/\S+@\S+/) { # full address
					$self->{-no_obfuscate}->{lc $_} = 1;
				} else {
					# allow "example.com" or "@example.com"
					s/\A@//;
					push @domains, quotemeta($_);
				}
			}
		}
		my $nod = join('|', @domains);
		$self->{-no_obfuscate_re} = qr/(?:$nod)\z/i;
	}
	if (my $css = delete $self->{'publicinbox.css'}) {
		$self->{css} = _array($css);
	}

	$self;
}

sub lookup {
	my ($self, $recipient) = @_;
	my $addr = lc($recipient);
	my $inbox = $self->{-by_addr}->{$addr};
	return $inbox if $inbox;

	my $pfx;

	foreach my $k (keys %$self) {
		$k =~ m!\A(publicinbox\.[^/]+)\.address\z! or next;
		my $v = $self->{$k};
		if (ref($v) eq "ARRAY") {
			foreach my $alias (@$v) {
				(lc($alias) eq $addr) or next;
				$pfx = $1;
				last;
			}
		} else {
			(lc($v) eq $addr) or next;
			$pfx = $1;
			last;
		}
	}
	defined $pfx or return;
	_fill($self, $pfx);
}

sub lookup_name ($$) {
	my ($self, $name) = @_;
	$self->{-by_name}->{$name} || _fill($self, "publicinbox.$name");
}

sub each_inbox {
	my ($self, $cb) = @_;
	if (my $section_order = $self->{-section_order}) {
		foreach my $section (@$section_order) {
			next if $section !~ m!\Apublicinbox\.([^/]+)\z!;
			$self->{"publicinbox.$1.mainrepo"} or next;
			my $ibx = lookup_name($self, $1) or next;
			$cb->($ibx);
		}
	} else {
		my %seen;
		foreach my $k (keys %$self) {
			$k =~ m!\Apublicinbox\.([^/]+)\.mainrepo\z! or next;
			next if $seen{$1};
			$seen{$1} = 1;
			my $ibx = lookup_name($self, $1) or next;
			$cb->($ibx);
		}
	}
}

sub lookup_newsgroup {
	my ($self, $ng) = @_;
	$ng = lc($ng);
	my $rv = $self->{-by_newsgroup}->{$ng};
	return $rv if $rv;

	foreach my $k (keys %$self) {
		$k =~ m!\A(publicinbox\.[^/]+)\.newsgroup\z! or next;
		my $v = $self->{$k};
		my $pfx = $1;
		if ($v eq $ng) {
			$rv = _fill($self, $pfx);
			return $rv;
		}
	}
	undef;
}

sub limiter {
	my ($self, $name) = @_;
	$self->{-limiters}->{$name} ||= do {
		require PublicInbox::Qspawn;
		my $max = $self->{"publicinboxlimiter.$name.max"} || 1;
		my $limiter = PublicInbox::Qspawn::Limiter->new($max);
		$limiter->setup_rlimit($name, $self);
		$limiter;
	};
}

sub config_dir { $ENV{PI_DIR} || "$ENV{HOME}/.public-inbox" }

sub default_file {
	my $f = $ENV{PI_CONFIG};
	return $f if defined $f;
	config_dir() . '/config';
}

sub git_config_dump {
	my ($file) = @_;
	my (%section_seen, @section_order);
	return {} unless -e $file;
	my @cmd = (qw/git config/, "--file=$file", '-l');
	my $cmd = join(' ', @cmd);
	my $fh = popen_rd(\@cmd) or die "popen_rd failed for $file: $!\n";
	my %rv;
	local $/ = "\n";
	while (defined(my $line = <$fh>)) {
		chomp $line;
		my ($k, $v) = split(/=/, $line, 2);

		my ($section) = ($k =~ /\A(\S+)\.[^\.]+\z/);
		unless (defined $section_seen{$section}) {
			$section_seen{$section} = 1;
			push @section_order, $section;
		}

		my $cur = $rv{$k};
		if (defined $cur) {
			if (ref($cur) eq "ARRAY") {
				push @$cur, $v;
			} else {
				$rv{$k} = [ $cur, $v ];
			}
		} else {
			$rv{$k} = $v;
		}
	}
	close $fh or die "failed to close ($cmd) pipe: $?";
	$rv{-section_order} = \@section_order;

	\%rv;
}

sub valid_inbox_name ($) {
	my ($name) = @_;

	# Similar rules found in git.git/remote.c::valid_remote_nick
	# and git.git/refs.c::check_refname_component
	# We don't reject /\.lock\z/, however, since we don't lock refs
	if ($name eq '' || $name =~ /\@\{/ ||
	    $name =~ /\.\./ || $name =~ m![/:\?\[\]\^~\s\f[:cntrl:]\*]! ||
	    $name =~ /\A\./ || $name =~ /\.\z/) {
		return 0;
	}

	# Note: we allow URL-unfriendly characters; users may configure
	# non-HTTP-accessible inboxes
	1;
}

sub cgit_repo_merge ($$) {
	my ($self, $repo) = @_;
	# $repo = { url => 'foo.git', path => '/path/to/foo.git' }
	my $nick = $repo->{url};
	$self->{"coderepo.$nick.dir"} ||= $repo->{path};
	$self->{"coderepo.$nick.cgiturl"} ||= $nick;
}

sub is_git_dir ($) {
	my ($git_dir) = @_;
	-d "$git_dir/objects" && -f "$git_dir/HEAD";
}

sub scan_path_coderepo {
	my ($self, $base, $path) = @_;
	opendir my $dh, $path or return;
	while (defined(my $dn = readdir $dh)) {
		next if $dn eq '.' || $dn eq '..';
		if (index($dn, '.') == 0 && !$self->{-cgit_scan_hidden_path}) {
			next;
		}
		my $nick = $base eq '' ? $dn : "$base/$dn";
		my $git_dir = "$path/$dn";
		if (is_git_dir($git_dir)) {
			my $repo = { url => $nick, path => $git_dir };
			cgit_repo_merge($self, $repo);
		} elsif (-d $git_dir) {
			scan_path_coderepo($self, $nick, $git_dir);
		}
	}
}

sub parse_cgitrc {
	my ($self, $cgitrc, $nesting) = @_;
	if ($nesting == 0) {
		# defaults:
		my %s = map { $_ => 1 } qw(/cgit.css /cgit.png
						/favicon.ico /robots.txt);
		$self->{-cgit_static} = \%s;
	}

	# same limit as cgit/configfile.c::parse_configfile
	return if $nesting > 8;

	open my $fh, '<', $cgitrc or do {
		warn "failed to open cgitrc=$cgitrc: $!\n";
		return;
	};

	# FIXME: this doesn't support macro expansion via $VARS, yet
	my $repo;
	foreach (<$fh>) {
		chomp;
		if (m!\Arepo\.url=(.+?)/*\z!) {
			my $nick = $1;
			cgit_repo_merge($self, $repo) if $repo;
			$repo = { url => $nick };
		} elsif (m!\Arepo\.path=(.+)\z!) {
			if (defined $repo) {
				$repo->{path} = $1;
			} else {
				warn "$_ without repo.url\n";
			}
		} elsif (m!\Ainclude=(.+)\z!) {
			parse_cgitrc($self, $1, $nesting + 1);
		} elsif (m!\Ascan-hidden-path=(\d+)\z!) {
			$self->{-cgit_scan_hidden_path} = $1;
		} elsif (m!\Ascan-path=(.+)\z!) {
			scan_path_coderepo($self, '', $1);

		} elsif (m!\A(?:css|favicon|logo|repo\.logo)=(/.+)\z!) {
			# absolute paths for static files via PublicInbox::Cgit
			$self->{-cgit_static}->{$1} = 1;
		}
	}
	cgit_repo_merge($self, $repo) if $repo;
}

# parse a code repo
# Only git is supported at the moment, but SVN and Hg are possibilities
sub _fill_code_repo {
	my ($self, $nick) = @_;
	my $pfx = "coderepo.$nick";

	# TODO: support gitweb and other repository viewers?
	if (defined(my $cgitrc = delete $self->{-cgitrc_unparsed})) {
		parse_cgitrc($self, $cgitrc, 0);
	}
	my $dir = $self->{"$pfx.dir"}; # aka "GIT_DIR"
	unless (defined $dir) {
		warn "$pfx.dir unset";
		return;
	}

	my $git = PublicInbox::Git->new($dir);
	foreach my $t (qw(blob commit tree tag)) {
		$git->{$t.'_url_format'} =
				_array($self->{lc("$pfx.${t}UrlFormat")});
	}

	if (my $cgits = $self->{lc("$pfx.cgitUrl")}) {
		$git->{cgit_url} = $cgits = _array($cgits);

		# cgit supports "/blob/?id=%s", but it's only a plain-text
		# display and requires an unabbreviated id=
		foreach my $t (qw(blob commit tag)) {
			$git->{$t.'_url_format'} ||= map {
				"$_/$t/?id=%s"
			} @$cgits;
		}
	}

	$git;
}

sub _fill {
	my ($self, $pfx) = @_;
	my $rv = {};

	foreach my $k (qw(mainrepo filter url newsgroup
			infourl watch watchheader httpbackendmax
			replyto feedmax nntpserver indexlevel)) {
		my $v = $self->{"$pfx.$k"};
		$rv->{$k} = $v if defined $v;
	}
	foreach my $k (qw(obfuscate)) {
		my $v = $self->{"$pfx.$k"};
		defined $v or next;
		if ($v =~ /\A(?:false|no|off|0)\z/) {
			$rv->{$k} = 0;
		} elsif ($v =~ /\A(?:true|yes|on|1)\z/) {
			$rv->{$k} = 1;
		} else {
			warn "Ignoring $pfx.$k=$v in config, not boolean\n";
		}
	}
	# TODO: more arrays, we should support multi-value for
	# more things to encourage decentralization
	foreach my $k (qw(address altid nntpmirror coderepo)) {
		if (defined(my $v = $self->{"$pfx.$k"})) {
			$rv->{$k} = _array($v);
		}
	}

	return unless $rv->{mainrepo};
	my $name = $pfx;
	$name =~ s/\Apublicinbox\.//;

	if (!valid_inbox_name($name)) {
		warn "invalid inbox name: '$name'\n";
		return;
	}

	$rv->{name} = $name;
	$rv->{-pi_config} = $self;
	$rv = PublicInbox::Inbox->new($rv);
	foreach (@{$rv->{address}}) {
		my $lc_addr = lc($_);
		$self->{-by_addr}->{$lc_addr} = $rv;
		$self->{-no_obfuscate}->{$lc_addr} = 1;
	}
	if (my $ng = $rv->{newsgroup}) {
		$self->{-by_newsgroup}->{$ng} = $rv;
	}
	$self->{-by_name}->{$name} = $rv;
	if ($rv->{obfuscate}) {
		$rv->{-no_obfuscate} = $self->{-no_obfuscate};
		$rv->{-no_obfuscate_re} = $self->{-no_obfuscate_re};
		each_inbox($self, sub {}); # noop to populate -no_obfuscate
	}

	if (my $ibx_code_repos = $rv->{coderepo}) {
		my $code_repos = $self->{-code_repos};
		my $repo_objs = $rv->{-repo_objs} = [];
		foreach my $nick (@$ibx_code_repos) {
			my @parts = split(m!/!, $nick);
			my $valid = 0;
			$valid += valid_inbox_name($_) foreach (@parts);
			$valid == scalar(@parts) or next;

			my $repo = $code_repos->{$nick} ||=
						_fill_code_repo($self, $nick);
			push @$repo_objs, $repo if $repo;
		}
	}

	$rv
}

1;
