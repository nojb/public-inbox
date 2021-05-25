# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# "lei forget-mail-sync" drop synchronization information
# TODO: figure out what to do about "lei index" users having
# dangling references.  Perhaps just documenting "lei index"
# use being incompatible with "forget-mail-sync" use is
# sufficient.

package PublicInbox::LeiForgetMailSync;
use strict;
use v5.10.1;
use PublicInbox::LeiExportKw;

sub lei_forget_mail_sync {
	my ($lei, @folders) = @_;
	my $sto = $lei->_lei_store or return;
	my $lms = $sto->search->lms or return;
	my $err = $lms->arg2folder($lei, \@folders);
	$lei->qerr(@{$err->{qerr}}) if $err->{qerr};
	return $lei->fail($err->{fail}) if $err->{fail};
	delete $lms->{dbh};
	$lms->lms_begin;
	$lms->forget_folder($_) for @folders;
	$lms->lms_commit;
}

*_complete_forget_mail_sync = \&PublicInbox::LeiExportKw::_complete_export_kw;

1;
