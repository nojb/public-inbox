# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# *-external commands of lei
package PublicInbox::LeiExternal;
use strict;
use v5.10.1;
use PublicInbox::Config;

sub externals_each {
	my ($self, $cb, @arg) = @_;
	my $cfg = $self->_lei_cfg;
	my %boost;
	for my $sec (grep(/\Aexternal\./, @{$cfg->{-section_order}})) {
		my $loc = substr($sec, length('external.'));
		$boost{$loc} = $cfg->{"$sec.boost"};
	}
	return \%boost if !wantarray && !$cb;

	# highest boost first, but stable for alphabetic tie break
	use sort 'stable';
	my @order = sort { $boost{$b} <=> $boost{$a} } sort keys %boost;
	if (ref($cb) eq 'CODE') {
		for my $loc (@order) {
			$cb->(@arg, $loc, $boost{$loc});
		}
	} elsif (ref($cb) eq 'HASH') {
		%$cb = %boost;
	}
	@order; # scalar or array
}

sub ext_canonicalize {
	my ($location) = @_;
	if ($location !~ m!\Ahttps?://!) {
		PublicInbox::Config::rel2abs_collapsed($location);
	} else {
		require URI;
		my $uri = URI->new($location)->canonical;
		my $path = $uri->path . '/';
		$path =~ tr!/!/!s; # squeeze redundant '/'
		$uri->path($path);
		$uri->as_string;
	}
}

# TODO: we will probably extract glob2re into a separate module for
# PublicInbox::Filter::Base and maybe other places
my %re_map = ( '*' => '[^/]*?', '?' => '[^/]',
		'[' => '[', ']' => ']', ',' => ',' );

sub glob2re {
	my $re = $_[-1];
	my $p = '';
	my $in_bracket = 0;
	my $qm = 0;
	my $schema_host_port = '';

	# don't glob URL-looking things that look like IPv6
	if ($re =~ s!\A([a-z0-9\+]+://\[[a-f0-9\:]+\](?::[0-9]+)?/)!!i) {
		$schema_host_port = quotemeta $1; # "http://[::1]:1234"
	}
	my $changes = ($re =~ s!(.)!
		$re_map{$p eq '\\' ? '' : do {
			if ($1 eq '[') { ++$in_bracket }
			elsif ($1 eq ']') { --$in_bracket }
			elsif ($1 eq ',') { ++$qm } # no change
			$p = $1;
		}} // do {
			$p = $1;
			($p eq '-' && $in_bracket) ? $p : (++$qm, "\Q$p")
		}!sge);
	# bashism (also supported by curl): {a,b,c} => (a|b|c)
	$changes += ($re =~ s/([^\\]*)\\\{([^,]*,[^\\]*)\\\}/
			(my $in_braces = $2) =~ tr!,!|!;
			$1."($in_braces)";
			/sge);
	($changes - $qm) ? $schema_host_port.$re : undef;
}

# get canonicalized externals list matching $loc
# $is_exclude denotes it's for --exclude
# otherwise it's for --only/--include is assumed
sub get_externals {
	my ($self, $loc, $is_exclude) = @_;
	return (ext_canonicalize($loc)) if -e $loc;
	my @m;
	my @cur = externals_each($self);
	my $do_glob = !$self->{opt}->{globoff}; # glob by default
	if ($do_glob && (my $re = glob2re($loc))) {
		@m = grep(m!$re!, @cur);
		return @m if scalar(@m);
	} elsif (index($loc, '/') < 0) { # exact basename match:
		@m = grep(m!/\Q$loc\E/?\z!, @cur);
		return @m if scalar(@m) == 1;
	} elsif ($is_exclude) { # URL, maybe:
		my $canon = ext_canonicalize($loc);
		@m = grep(m!\A\Q$canon\E\z!, @cur);
		return @m if scalar(@m) == 1;
	} else { # URL:
		return (ext_canonicalize($loc));
	}
	if (scalar(@m) == 0) {
		$self->fail("`$loc' is unknown");
	} else {
		$self->fail("`$loc' is ambiguous:\n", map { "\t$_\n" } @m);
	}
	();
}

# TODO: does this need JSON output?
sub lei_ls_external {
	my ($self, $filter) = @_;
	my $opt = $self->{opt};
	my $do_glob = !$opt->{globoff}; # glob by default
	my ($OFS, $ORS) = $opt->{z} ? ("\0", "\0\0") : (" ", "\n");
	$filter //= '*';
	my $re = $do_glob ? glob2re($filter) : undef;
	$re //= index($filter, '/') < 0 ?
			qr!/\Q$filter\E/?\z! : # exact basename match
			qr/\Q$filter\E/; # grep -F semantics
	my @ext = externals_each($self, my $boost = {});
	@ext = $opt->{'invert-match'} ? grep(!/$re/, @ext)
					: grep(/$re/, @ext);
	if ($opt->{'local'} && !$opt->{remote}) {
		@ext = grep(!m!\A[a-z\+]+://!, @ext);
	} elsif ($opt->{remote} && !$opt->{'local'}) {
		@ext = grep(m!\A[a-z\+]+://!, @ext);
	}
	for my $loc (@ext) {
		$self->out($loc, $OFS, 'boost=', $boost->{$loc}, $ORS);
	}
}

sub add_external_finish {
	my ($self, $location) = @_;
	my $cfg = $self->_lei_cfg(1);
	my $new_boost = $self->{opt}->{boost} // 0;
	my $key = "external.$location.boost";
	my $cur_boost = $cfg->{$key};
	return if defined($cur_boost) && $cur_boost == $new_boost; # idempotent
	$self->_config($key, $new_boost);
}

sub lei_add_external {
	my ($self, $location) = @_;
	my $opt = $self->{opt};
	my $mirror = $opt->{mirror} // do {
		my @fail;
		for my $sw ($self->index_opt, $self->curl_opt,
				qw(no-torsocks torsocks inbox-version)) {
			my ($f) = (split(/|/, $sw, 2))[0];
			next unless defined $opt->{$f};
			$f = length($f) == 1 ? "-$f" : "--$f";
			push @fail, $f;
		}
		if (scalar(@fail) == 1) {
			return $self->("@fail requires --mirror");
		} elsif (@fail) {
			my $last = pop @fail;
			my $fail = join(', ', @fail);
			return $self->("@fail and $last require --mirror");
		}
		undef;
	};
	my $new_boost = $opt->{boost} // 0;
	$location = ext_canonicalize($location);
	if (defined($mirror) && -d $location) {
		$self->fail(<<""); # TODO: did you mean "update-external?"
--mirror destination `$location' already exists

	} elsif (-d $location) {
		index($location, "\n") >= 0 and
			return $self->fail("`\\n' not allowed in `$location'");
	}
	if ($location !~ m!\Ahttps?://! && !-d $location) {
		$mirror // return $self->fail("$location not a directory");
		index($location, "\n") >= 0 and
			return $self->fail("`\\n' not allowed in `$location'");
		$mirror = ext_canonicalize($mirror);
		require PublicInbox::LeiMirror;
		PublicInbox::LeiMirror->start($self, $mirror => $location);
	} else {
		add_external_finish($self, $location);
	}
}

sub lei_forget_external {
	my ($self, @locations) = @_;
	my $cfg = $self->_lei_cfg(1);
	my $quiet = $self->{opt}->{quiet};
	my %seen;
	for my $loc (@locations) {
		my (@unset, @not_found);
		for my $l ($loc, ext_canonicalize($loc)) {
			next if $seen{$l}++;
			my $key = "external.$l.boost";
			delete($cfg->{$key});
			$self->_config('--unset', $key);
			if ($? == 0) {
				push @unset, $l;
			} elsif (($? >> 8) == 5) {
				push @not_found, $l;
			} else {
				$self->err("# --unset $key error");
				return $self->x_it($?);
			}
		}
		if (@unset) {
			next if $quiet;
			$self->err("# $_ gone") for @unset;
		} elsif (@not_found) {
			$self->err("# $_ not found") for @not_found;
		} # else { already exited
	}
}

# returns an anonymous sub which returns an array of potential results
sub complete_url_prepare {
	my $argv = $_[-1];
	# Workaround bash word-splitting URLs to ['https', ':', '//' ...]
	# Maybe there's a better way to go about this in
	# contrib/completion/lei-completion.bash
	my $re = '';
	my $cur = pop(@$argv) // '';
	if (@$argv) {
		my @x = @$argv;
		if ($cur eq ':' && @x) {
			push @x, $cur;
			$cur = '';
		}
		while (@x > 2 && $x[0] !~ /\A(?:http|nntp|imap)s?\z/i &&
				$x[1] ne ':') {
			shift @x;
		}
		if (@x >= 2) { # qw(https : hostname : 443) or qw(http :)
			$re = join('', @x);
		} else { # just filter out the flags and hope for the best
			$re = join('', grep(!/^-/, @$argv));
		}
		$re = quotemeta($re);
	}
	my $match_cb = sub {
		# the "//;" here (for AUTH=ANONYMOUS) interacts badly with
		# bash tab completion, strip it out for now since our commands
		# work w/o it.  Not sure if there's a better solution...
		$_[0] =~ s!//;AUTH=ANONYMOUS\@!//!i;
		$_[0] =~ s!;!\\;!g;
		# only return the part specified on the CLI
		# don't duplicate if already 100% completed
		$_[0] =~ /\A$re(\Q$cur\E.*)/ ? ($cur eq $1 ? () : $1) : ()
	};
	wantarray ? ($re, $cur, $match_cb) : $match_cb;
}

# shell completion helper called by lei__complete
sub _complete_forget_external {
	my ($self, @argv) = @_;
	my $cfg = $self->_lei_cfg;
	my ($cur, $re, $match_cb) = complete_url_prepare(\@argv);
	# FIXME: bash completion off "http:" or "https:" when the last
	# character is a colon doesn't work properly even if we're
	# returning "//$HTTP_HOST/$PATH_INFO/", not sure why, could
	# be a bash issue.
	map {
		$match_cb->(substr($_, length('external.')));
	} grep(/\Aexternal\.$re\Q$cur/, @{$cfg->{-section_order}});
}

sub _complete_add_external { # for bash, this relies on "compopt -o nospace"
	my ($self, @argv) = @_;
	my $cfg = $self->_lei_cfg;
	my $match_cb = complete_url_prepare(\@argv);
	require URI;
	map {
		my $u = URI->new(substr($_, length('external.')));
		my ($base) = ($u->path =~ m!((?:/?.*)?/)[^/]+/?\z!);
		$u->path($base);
		$match_cb->($u->as_string);
	} grep(m!\Aexternal\.https?://!, @{$cfg->{-section_order}});
}

1;
