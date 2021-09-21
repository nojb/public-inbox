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
use PublicInbox::LeiRefreshMailSync;

sub lei_forget_mail_sync {
	my ($lei, @folders) = @_;
	my $lms = $lei->lms or return;
	$lms->lms_write_prepare;
	$lms->arg2folder($lei, \@folders); # may die
	$lms->forget_folders(@folders);
}

*_complete_forget_mail_sync =
	\&PublicInbox::LeiRefreshMailSync::_complete_refresh_mail_sync;

1;
