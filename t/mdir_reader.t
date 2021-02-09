#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use PublicInbox::TestCommon;
require_ok 'PublicInbox::MdirReader';
*maildir_basename_flags = \&PublicInbox::MdirReader::maildir_basename_flags;
*maildir_path_flags = \&PublicInbox::MdirReader::maildir_path_flags;

is(maildir_basename_flags('foo'), '', 'new valid name accepted');
is(maildir_basename_flags('foo:2,'), '', 'cur valid name accepted');
is(maildir_basename_flags('foo:2,bar'), 'bar', 'flags name accepted');
is(maildir_basename_flags('.foo:2,bar'), undef, 'no hidden files');
is(maildir_basename_flags('fo:o:2,bar'), undef, 'no extra colon');
is(maildir_path_flags('/path/to/foo:2,S'), 'S', 'flag returned for path');
is(maildir_path_flags('/path/to/.foo:2,S'), undef, 'no hidden paths');
is(maildir_path_flags('/path/to/foo:2,'), '', 'no flags in path');

# not sure if there's a better place for eml_from_path
use_ok 'PublicInbox::InboxWritable', qw(eml_from_path);
is(eml_from_path('.'), undef, 'eml_from_path fails on directory');

done_testing;
