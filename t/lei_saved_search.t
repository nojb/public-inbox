#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use PublicInbox::TestCommon;
require_mods(qw(DBD::SQLite));
use_ok 'PublicInbox::LeiSavedSearch';

done_testing;
