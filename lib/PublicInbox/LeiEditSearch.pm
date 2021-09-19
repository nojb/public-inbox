# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# "lei edit-search" edit a saved search following "lei q --save"
package PublicInbox::LeiEditSearch;
use strict;
use v5.10.1;
use PublicInbox::LeiSavedSearch;
use PublicInbox::LeiUp;
use parent qw(PublicInbox::LeiConfig);

sub cfg_edit_begin {
	my ($self) = @_;
	if (ref($self->{lss}->{-cfg}->{'lei.q.output'})) {
		delete $self->{lss}->{-cfg}->{'lei.q.output'}; # invalid
		$self->{lei}->pgr_err(<<EOM);
$self->{lss}->{-f} has multiple values of lei.q.output
please remove redundant ones
EOM
	}
}

sub cfg_verify {
	my ($self, $cfg) = @_;
	my $new_out = $cfg->{'lei.q.output'} // '';
	return $self->cfg_do_edit(<<EOM) if ref $new_out;
$self->{-f} has multiple values of lei.q.output
EOM
	return $self->cfg_do_edit(<<EOM) if $new_out eq '';
$self->{-f} needs lei.q.output
EOM
	my $lss = $self->{lss};
	my $old_out = $lss->{-cfg}->{'lei.q.output'} // return;
	return if $old_out eq $new_out;
	my $lei = $self->{lei};
	my $old_path = $old_out;
	my $new_path = $new_out;
	s!$PublicInbox::LeiSavedSearch::LOCAL_PFX!! for ($old_path, $new_path);
	my $dir_old = $lss->can('lss_dir_for')->($lei, \$old_path, 1);
	my $dir_new = $lss->can('lss_dir_for')->($lei, \$new_path);
	return if $dir_new eq $dir_old;

	($old_out =~ m!\Av2:!i || $new_out =~ m!\Av2:!) and
		return $self->cfg_do_edit(<<EOM);
conversions from/to v2 inboxes not supported at this time
EOM
	return $self->cfg_do_edit(<<EOM) if -e $dir_new;
lei.q.output changed from `$old_out' to `$new_out'
However, $dir_new exists
EOM
	# start the conversion asynchronously
	my $old_sq = PublicInbox::Config::squote_maybe($old_out);
	my $new_sq = PublicInbox::Config::squote_maybe($new_out);
	$lei->puts("lei.q.output changed from $old_sq to $new_sq");
	$lei->qerr("# lei convert $old_sq -o $new_sq");
	my $v = !$lei->{opt}->{quiet};
	$lei->{opt} = { output => $new_out, verbose => $v };
	require PublicInbox::LeiConvert;
	PublicInbox::LeiConvert::lei_convert($lei, $old_out);

	$lei->fail(<<EOM) if -e $dir_old && !rename($dir_old, $dir_new);
E: rename($dir_old, $dir_new) error: $!
EOM
}

sub lei_edit_search {
	my ($lei, $out) = @_;
	my $lss = PublicInbox::LeiSavedSearch->up($lei, $out) or return;
	my $f = $lss->{-f};
	my $self = bless { lei => $lei, lss => $lss, -f => $f }, __PACKAGE__;
	$self->cfg_do_edit;
}

*_complete_edit_search = \&PublicInbox::LeiUp::_complete_up;

1;
