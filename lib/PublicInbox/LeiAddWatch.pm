# Copyright all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# "lei add-watch" command
package PublicInbox::LeiAddWatch;
use strict;
use v5.10.1;
use parent qw(PublicInbox::LeiInput);

sub lei_add_watch {
	my ($lei, @argv) = @_;
	my $cfg = $lei->_lei_cfg(1);
	my $self = bless {}, __PACKAGE__;
	$lei->{opt}->{'mail-sync'} = 1; # for prepare_inputs
	my $state = $lei->{opt}->{'state'} // 'import-rw';
	$lei->watch_state_ok($state) or
		return $lei->fail("invalid state: $state");
	my $vmd_mod = $self->vmd_mod_extract(\@argv);
	return $lei->fail(join("\n", @{$vmd_mod->{err}})) if $vmd_mod->{err};
	$self->prepare_inputs($lei, \@argv) or return;
	my @vmd;
	while (my ($type, $vals) = each %$vmd_mod) {
		push @vmd, "$type:$_" for @$vals;
	}
	my $vmd0 = shift @vmd;
	for my $w (@{$self->{inputs}}) {
		# clobber existing, allow multiple
		if (defined($vmd0)) {
			$lei->_config("watch.$w.vmd", '--replace-all', $vmd0);
			for my $v (@vmd) {
				$lei->_config("watch.$w.vmd", $v);
			}
		}
		next if defined $cfg->{"watch.$w.state"};
		$lei->_config("watch.$w.state", $state);
	}
	$lei->_lei_store(1); # create
	$lei->lms(1)->lms_write_prepare->add_folders(@{$self->{inputs}});
	delete $lei->{cfg}; # force reload
	$lei->refresh_watches;
}

1;
