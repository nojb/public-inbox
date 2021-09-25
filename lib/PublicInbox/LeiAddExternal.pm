# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# "lei add-external" command
package PublicInbox::LeiAddExternal;
use strict;
use v5.10.1;

sub _finish_add_external {
	my ($lei, $location) = @_;
	my $new_boost = $lei->{opt}->{boost} // 0;
	my $key = "external.$location.boost";
	my $cur_boost = $lei->_lei_cfg(1)->{$key};
	return if defined($cur_boost) && $cur_boost == $new_boost; # idempotent
	$lei->_config($key, $new_boost);
}

sub lei_add_external {
	my ($lei, $location) = @_;
	my $mirror = $lei->{opt}->{mirror} // do {
		my @fail;
		for my $sw ($lei->index_opt, $lei->curl_opt,
				qw(no-torsocks torsocks inbox-version)) {
			my ($f) = (split(/|/, $sw, 2))[0];
			next unless defined $lei->{opt}->{$f};
			$f = length($f) == 1 ? "-$f" : "--$f";
			push @fail, $f;
		}
		if (scalar(@fail) == 1) {
			return $lei->("@fail requires --mirror");
		} elsif (@fail) {
			my $last = pop @fail;
			my $fail = join(', ', @fail);
			return $lei->("@fail and $last require --mirror");
		}
		undef;
	};
	$location = $lei->ext_canonicalize($location);
	if (defined($mirror) && -d $location) {
		$lei->fail(<<""); # TODO: did you mean "update-external?"
--mirror destination `$location' already exists

	} elsif (-d $location) {
		index($location, "\n") >= 0 and
			return $lei->fail("`\\n' not allowed in `$location'");
	}
	if ($location !~ m!\Ahttps?://! && !-d $location) {
		$mirror // return $lei->fail("$location not a directory");
		index($location, "\n") >= 0 and
			return $lei->fail("`\\n' not allowed in `$location'");
		$mirror = $lei->ext_canonicalize($mirror);
		require PublicInbox::LeiMirror;
		PublicInbox::LeiMirror->start($lei, $mirror => $location);
	} else {
		_finish_add_external($lei, $location);
	}
}

sub _complete_add_external { # for bash, this relies on "compopt -o nospace"
	my ($lei, @argv) = @_;
	my $cfg = $lei->_lei_cfg or return ();
	my $match_cb = $lei->complete_url_prepare(\@argv);
	require URI;
	map {
		my $u = URI->new(substr($_, length('external.')));
		my ($base) = ($u->path =~ m!((?:/?.*)?/)[^/]+/?\z!);
		$u->path($base);
		$match_cb->($u->as_string);
	} grep(m!\Aexternal\.https?://!, @{$cfg->{-section_order}});
}

1;
