# Copyright (C) 2018-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::MIME;
use PublicInbox::Import;
use PublicInbox::TestCommon;

foreach my $mod (qw(DBD::SQLite Search::Xapian)) {
	eval "require $mod";
	plan skip_all => "$mod missing for v1-add-remove-add.t" if $@;
}
require PublicInbox::SearchIdx;
my ($inboxdir, $for_destroy) = tmpdir();
is(system(qw(git init --bare -q), $inboxdir), 0);
my $ibx = {
	inboxdir => $inboxdir,
	name => 'test-add-remove-add',
	-primary_address => 'test@example.com',
};
$ibx = PublicInbox::Inbox->new($ibx);
my $mime = PublicInbox::MIME->create(
	header => [
		From => 'a@example.com',
		To => 'test@example.com',
		Subject => 'this is a subject',
		Date => 'Fri, 02 Oct 1993 00:00:00 +0000',
		'Message-ID' => '<a-mid@b>',
	],
	body => "hello world\n",
);
my $im = PublicInbox::Import->new($ibx->git, undef, undef, $ibx);
ok($im->add($mime), 'message added');
ok($im->remove($mime), 'message added');
ok($im->add($mime), 'message added again');
$im->done;
my $rw = PublicInbox::SearchIdx->new($ibx, 1);
$rw->index_sync;
my $msgs = $ibx->recent({limit => 10});
is($msgs->[0]->{mid}, 'a-mid@b', 'message exists in history');
is(scalar @$msgs, 1, 'only one message in history');
is($ibx->mm->num_for('a-mid@b'), 2, 'exists with second article number');

done_testing();
