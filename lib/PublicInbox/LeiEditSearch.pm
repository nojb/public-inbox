# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# "lei edit-search" edit a saved search following "lei q --save"
package PublicInbox::LeiEditSearch;
use strict;
use v5.10.1;
use PublicInbox::LeiSavedSearch;
use PublicInbox::LeiUp;

sub edit_begin {
	my ($lss, $lei) = @_;
	if (ref($lss->{-cfg}->{'lei.q.output'})) {
		delete $lss->{-cfg}->{'lei.q.output'}; # invalid
		$lei->pgr_err(<<EOM);
$lss->{-f} has multiple values of lei.q.output
please remove redundant ones
EOM
	}
	$lei->{-lss_for_edit} = $lss;
}

sub do_edit ($$;$) {
	my ($lss, $lei, $reason) = @_;
	$lei->pgr_err($reason) if defined $reason;
	my @cmd = (qw(git config --edit -f), $lss->{'-f'});
	$lei->qerr("# spawning @cmd");
	edit_begin($lss, $lei);
	# run in script/lei foreground
	require PublicInbox::PktOp;
	my ($op_c, $op_p) = PublicInbox::PktOp->pair;
	# $op_p will EOF when $EDITOR is done
	$op_c->{ops} = { '' => [\&op_edit_done, $lss, $lei] };
	$lei->send_exec_cmd([ @$lei{qw(0 1 2)}, $op_p->{op_p} ], \@cmd, {});
}

sub _edit_done {
	my ($lss, $lei) = @_;
	my $cfg = $lss->can('cfg_dump')->($lei, $lss->{'-f'}) //
		return do_edit($lss, $lei, <<EOM);
$lss->{-f} is unparseable
EOM
	my $new_out = $cfg->{'lei.q.output'} // '';
	return do_edit($lss, $lei, <<EOM) if ref $new_out;
$lss->{-f} has multiple values of lei.q.output
EOM
	return do_edit($lss, $lei, <<EOM) if $new_out eq '';
$lss->{-f} needs lei.q.output
EOM
	my $old_out = $lss->{-cfg}->{'lei.q.output'} // return;
	return if $old_out eq $new_out;
	my $old_path = $old_out;
	my $new_path = $new_out;
	s!$PublicInbox::LeiSavedSearch::LOCAL_PFX!! for ($old_path, $new_path);
	my $dir_old = $lss->can('lss_dir_for')->($lei, \$old_path, 1);
	my $dir_new = $lss->can('lss_dir_for')->($lei, \$new_path);
	return if $dir_new eq $dir_old;

	($old_out =~ m!\Av2:!i || $new_out =~ m!\Av2:!) and
		return do_edit($lss, $lei, <<EOM);
conversions from/to v2 inboxes not supported at this time
EOM
	return do_edit($lss, $lei, <<EOM) if -e $dir_new;
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

sub op_edit_done { # PktOp
	my ($lss, $lei) = @_;
	eval { _edit_done($lss, $lei) };
	$lei->fail($@) if $@;
}

sub lei_edit_search {
	my ($lei, $out) = @_;
	my $lss = PublicInbox::LeiSavedSearch->up($lei, $out) or return;
	do_edit($lss, $lei);
}

*_complete_edit_search = \&PublicInbox::LeiUp::_complete_up;

1;
