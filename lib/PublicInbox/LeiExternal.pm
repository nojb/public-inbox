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
	my $location = $_[-1]; # $_[0] may be $lei
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
	my $re = $_[-1]; # $_[0] may be $lei
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
		die "`$loc' is unknown\n";
	} else {
		die("`$loc' is ambiguous:\n", map { "\t$_\n" } @m, "\n");
	}
	();
}

# returns an anonymous sub which returns an array of potential results
sub complete_url_prepare {
	my $argv = $_[-1]; # $_[0] may be $lei
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

1;
