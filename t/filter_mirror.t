# Copyright (C) 2016-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::TestCommon;
use_ok 'PublicInbox::Filter::Mirror';

my $f = PublicInbox::Filter::Mirror->new;
ok($f, 'created PublicInbox::Filter::Mirror object');
{
	my $email = eml_load 't/mda-mime.eml';
	is($f->ACCEPT, $f->delivery($email), 'accept any trash that comes');
}

 done_testing();
