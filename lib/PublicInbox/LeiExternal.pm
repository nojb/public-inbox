# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# *-external commands of lei
package PublicInbox::LeiExternal;
use strict;
use v5.10.1;
use parent qw(Exporter);
our @EXPORT = qw(lei_ls_external lei_add_external lei_forget_external);

sub lei_ls_external {
	my ($self, @argv) = @_;
	my $stor = $self->_lei_store(0);
	my $cfg = $self->_lei_cfg(0);
	my $out = $self->{1};
	my ($OFS, $ORS) = $self->{opt}->{z} ? ("\0", "\0\0") : (" ", "\n");
	my (%boost, @loc);
	for my $sec (grep(/\Aexternal\./, @{$cfg->{-section_order}})) {
		my $loc = substr($sec, length('external.'));
		$boost{$loc} = $cfg->{"$sec.boost"};
		push @loc, $loc;
	}
	use sort 'stable';
	# highest boost first, but stable for alphabetic tie break
	for (sort { $boost{$b} <=> $boost{$a} } sort keys %boost) {
		# TODO: use miscidx and show docid so forget/set is easier
		print $out $_, $OFS, 'boost=', $boost{$_}, $ORS;
	}
}

sub lei_add_external {
	my ($self, $url_or_dir) = @_;
	my $cfg = $self->_lei_cfg(1);
	if ($url_or_dir !~ m!\Ahttps?://!) {
		$url_or_dir = File::Spec->canonpath($url_or_dir);
	}
	my $new_boost = $self->{opt}->{boost} // 0;
	my $key = "external.$url_or_dir.boost";
	my $cur_boost = $cfg->{$key};
	return if defined($cur_boost) && $cur_boost == $new_boost; # idempotent
	$self->lei_config($key, $new_boost);
	my $stor = $self->_lei_store(1);
	# TODO: add to MiscIdx
	$stor->done;
}

sub lei_forget_external {
	# TODO
}

1;
