# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# *-external commands of lei
package PublicInbox::LeiExternal;
use strict;
use v5.10.1;
use parent qw(Exporter);
our @EXPORT = qw(lei_ls_external lei_add_external lei_forget_external);
use PublicInbox::Config;

sub _externals_each {
	my ($self, $cb, @arg) = @_;
	my $cfg = $self->_lei_cfg(0);
	my %boost;
	for my $sec (grep(/\Aexternal\./, @{$cfg->{-section_order}})) {
		my $loc = substr($sec, length('external.'));
		$boost{$loc} = $cfg->{"$sec.boost"};
	}
	return \%boost if !wantarray && !$cb;

	# highest boost first, but stable for alphabetic tie break
	use sort 'stable';
	my @order = sort { $boost{$b} <=> $boost{$a} } sort keys %boost;
	return @order if !$cb;
	for my $loc (@order) {
		$cb->(@arg, $loc, $boost{$loc});
	}
	@order; # scalar or array
}

sub lei_ls_external {
	my ($self, @argv) = @_;
	my $out = $self->{1};
	my ($OFS, $ORS) = $self->{opt}->{z} ? ("\0", "\0\0") : (" ", "\n");
	$self->_externals_each(sub {
		my ($loc, $boost_val) = @_;
		print $out $loc, $OFS, 'boost=', $boost_val, $ORS;
	});
}

sub _canonicalize {
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

sub lei_add_external {
	my ($self, $location) = @_;
	my $cfg = $self->_lei_cfg(1);
	my $new_boost = $self->{opt}->{boost} // 0;
	$location = _canonicalize($location);
	my $key = "external.$location.boost";
	my $cur_boost = $cfg->{$key};
	return if defined($cur_boost) && $cur_boost == $new_boost; # idempotent
	$self->lei_config($key, $new_boost);
	$self->_lei_store(1)->done; # just create the store
}

sub lei_forget_external {
	my ($self, @locations) = @_;
	my $cfg = $self->_lei_cfg(1);
	my $quiet = $self->{opt}->{quiet};
	for my $loc (@locations) {
		my (@unset, @not_found);
		for my $l ($loc, _canonicalize($loc)) {
			my $key = "external.$l.boost";
			delete($cfg->{$key});
			$self->_config('--unset', $key);
			if ($? == 0) {
				push @unset, $key;
			} elsif (($? >> 8) == 5) {
				push @not_found, $key;
			} else {
				$self->err("# --unset $key error");
				return $self->x_it($?);
			}
		}
		if (@unset) {
			next if $quiet;
			$self->err("# $_ unset") for @unset;
		} elsif (@not_found) {
			$self->err("# $_ not found") for @not_found;
		} # else { already exited
	}
}

# shell completion helper called by lei__complete
sub _complete_forget_external {
	my ($self, @argv) = @_;
	my $cfg = $self->_lei_cfg(0);
	my $cur = pop @argv;
	# Workaround bash word-splitting URLs to ['https', ':', '//' ...]
	# Maybe there's a better way to go about this in
	# contrib/completion/lei-completion.bash
	my $colon = ($argv[-1] // '') eq ':';
	my $re = $cur =~ /\A[\w-]/ ? '' : '.*';
	map {
		my $x = substr($_, length('external.'));
		# only return the part specified on the CLI
		$colon && $x =~ /(\Q$cur\E.*)/ ? $1 : $x;
	} grep(/\Aexternal\.$re\Q$cur/, @{$cfg->{-section_order}});
}

1;
