# Copyright (C) 2016-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::TestCommon;
use_ok 'PublicInbox::Filter::Base';

{
	my $f = PublicInbox::Filter::Base->new;
	ok($f, 'created stock object');
	ok(defined $f->{reject_suffix}, 'rejected suffix redefined');
	is(ref($f->{reject_suffix}), 'Regexp', 'reject_suffix should be a RE');
}

{
	my $f = PublicInbox::Filter::Base->new(reject_suffix => undef);
	ok($f, 'created base object q/o reject_suffix');
	ok(!defined $f->{reject_suffix}, 'reject_suffix not defined');
}

{
	my $f = PublicInbox::Filter::Base->new;
	my $email = eml_load 't/filter_base-xhtml.eml';
	is($f->delivery($email), 100, "xhtml rejected");
}

{
	my $f = PublicInbox::Filter::Base->new;
	my $email = eml_load 't/filter_base-junk.eml';
	is($f->delivery($email), 100, 'proprietary format rejected on glob');
}

done_testing();
