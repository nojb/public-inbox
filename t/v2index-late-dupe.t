# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# this simulates a mirror path: git fetch && -index
use strict; use v5.10.1; use PublicInbox::TestCommon;
use Test::More; # redundant, used for bisect
require_mods 'v2';
require PublicInbox::Import;
require PublicInbox::Inbox;
require PublicInbox::Git;
my ($tmpdir, $for_destroy) = tmpdir();
my $inboxdir = "$tmpdir/i";
local $ENV{HOME} = $tmpdir;
PublicInbox::Import::init_bare(my $e0 = "$inboxdir/git/0.git");
open my $fh, '>', "$inboxdir/inbox.lock" or xbail $!;
my $git = PublicInbox::Git->new($e0);
my $im = PublicInbox::Import->new($git, qw(i i@example.com));
$im->{lock_path} = undef;
$im->{path_type} = 'v2';
my $eml = eml_load('t/plack-qp.eml');
ok($im->add($eml), 'add original');
$im->done;
run_script([qw(-index -Lbasic), $inboxdir]);
is($?, 0, 'basic index');
my $ibx = PublicInbox::Inbox->new({ inboxdir => $inboxdir });
my $orig = $ibx->over->get_art(1);

my @mid = $eml->header_raw('Message-ID');
$eml->header_set('Message-ID', @mid, '<extra@z>');
ok($im->add($eml), 'add another');
$im->done;
run_script([qw(-index -Lbasic), $inboxdir]);
is($?, 0, 'basic index again');

my $after = $ibx->over->get_art(1);
is_deeply($after, $orig, 'original unchanged') or note explain([$orig,$after]);

done_testing;
