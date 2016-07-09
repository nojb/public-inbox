# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Represents a public-inbox (which may have multiple mailing addresses)
package PublicInbox::Inbox;
use strict;
use warnings;
use Scalar::Util qw(weaken isweak);
use PublicInbox::Git;
use PublicInbox::MID qw(mid2path);

my $weakt;
eval {
	$weakt = 'disabled';
	require PublicInbox::EvCleanup;
	$weakt = undef; # OK if we get here
};

my $WEAKEN = {}; # string(inbox) -> inbox
sub weaken_task () {
	$weakt = undef;
	_weaken_fields($_) for values %$WEAKEN;
	$WEAKEN = {};
}

sub _weaken_later ($) {
	my ($self) = @_;
	$weakt ||= PublicInbox::EvCleanup::later(*weaken_task);
	$WEAKEN->{"$self"} = $self;
}

sub new {
	my ($class, $opts) = @_;
	my $v = $opts->{address} ||= 'public-inbox@example.com';
	my $p = $opts->{-primary_address} = ref($v) eq 'ARRAY' ? $v->[0] : $v;
	$opts->{domain} = ($p =~ /\@(\S+)\z/) ? $1 : 'localhost';
	weaken($opts->{-pi_config});
	bless $opts, $class;
}

sub _weaken_fields {
	my ($self) = @_;
	foreach my $f (qw(git mm search)) {
		isweak($self->{$f}) or weaken($self->{$f});
	}
}

sub _set_limiter ($$$) {
	my ($self, $git, $pfx) = @_;
	my $lkey = "-${pfx}_limiter";
	$git->{$lkey} = $self->{$lkey} ||= eval {
		my $mkey = $pfx.'max';
		my $val = $self->{$mkey} or return;
		my $lim;
		if ($val =~ /\A\d+\z/) {
			require PublicInbox::Qspawn;
			$lim = PublicInbox::Qspawn::Limiter->new($val);
		} elsif ($val =~ /\A[a-z][a-z0-9]*\z/) {
			$lim = $self->{-pi_config}->limiter($val);
			warn "$mkey limiter=$val not found\n" if !$lim;
		} else {
			warn "$mkey limiter=$val not understood\n";
		}
		$lim;
	}
}

sub git {
	my ($self) = @_;
	$self->{git} ||= eval {
		_weaken_later($self);
		my $g = PublicInbox::Git->new($self->{mainrepo});
		_set_limiter($self, $g, 'httpbackend');
		$g;
	};
}

sub mm {
	my ($self) = @_;
	$self->{mm} ||= eval {
		_weaken_later($self);
		PublicInbox::Msgmap->new($self->{mainrepo});
	};
}

sub search {
	my ($self) = @_;
	$self->{search} ||= eval {
		_weaken_later($self);
		PublicInbox::Search->new($self->{mainrepo});
	};
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
	chomp $desc;
	$desc =~ s/\s+/ /smg;
	$desc = '($GIT_DIR/description missing)' if $desc eq '';
	$self->{description} = $desc;
}

sub cloneurl {
	my ($self) = @_;
	my $url = $self->{cloneurl};
	return $url if $url;
	$url = try_cat("$self->{mainrepo}/cloneurl");
	my @url = split(/\s+/s, $url);
	chomp @url;
	$self->{cloneurl} = \@url;
}

sub base_url {
	my ($self, $env) = @_;
	if ($env) { # PSGI env
		my $scheme = $env->{'psgi.url_scheme'};
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

sub nntp_usable {
	my ($self) = @_;
	my $ret = $self->mm && $self->search;
	$self->{mm} = $self->{search} = undef;
	$ret;
}

sub msg_by_path ($$;$) {
	my ($self, $path, $ref) = @_;
	# TODO: allow other refs:
	my $str = git($self)->cat_file('HEAD:'.$path, $ref);
	$$str =~ s/\A[\r\n]*From [^\r\n]*\r?\n//s if $str;
	$str;
}

sub path_check {
	my ($self, $path) = @_;
	git($self)->check('HEAD:'.$path);
}

sub msg_by_mid ($$;$) {
	my ($self, $mid, $ref) = @_;
	msg_by_path($self, mid2path($mid), $ref);
}

1;
