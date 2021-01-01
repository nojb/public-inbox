#!perl -w
# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use PublicInbox::TestCommon;
$PublicInbox::TestCommon::cached_scripts{'lei-oneshot'} //= do {
	eval <<'EOF';
package LeiOneshot;
use strict;
use subs qw(exit);
*exit = \&PublicInbox::TestCommon::run_script_exit;
sub main {
# the below "line" directive is a magic comment, see perlsyn(1) manpage
# line 1 "lei-oneshot"
	require PublicInbox::LEI;
	PublicInbox::LEI::oneshot(__PACKAGE__);
	0;
}
1;
EOF
	LeiOneshot->can('main');
};
local $ENV{TEST_LEI_ONESHOT} = '1';
require './t/lei.t';
