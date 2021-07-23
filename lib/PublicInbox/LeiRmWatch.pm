# Copyright all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# "lei rm-watch" command
package PublicInbox::LeiRmWatch;
use strict;
use v5.10.1;
use parent qw(PublicInbox::LeiInput);

sub lei_rm_watch {
	my ($lei, @argv) = @_;
	my $cfg = $lei->_lei_cfg(1);
	$lei->{opt}->{'mail-sync'} = 1; # for prepare_inputs
	my $self = bless { missing_ok => 1 }, __PACKAGE__;
	$self->prepare_inputs($lei, \@argv) or return;
	for my $w (@{$self->{inputs}}) {
		$lei->_config('--remove-section', "watch.$w");
	}
	delete $lei->{cfg}; # force reload
	$lei->refresh_watches;
}

sub _complete_rm_watch {
	my ($lei, @argv) = @_;
	my $cfg = $lei->_lei_cfg or return;
	my $match_cb = $lei->complete_url_prepare(\@argv);
	my @w = (join("\n", keys %$cfg) =~ m/^watch\.(.+?)\.state$/sgm);
	map { $match_cb->($_) } @w;
}

1;
