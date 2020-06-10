#!perl -w
# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use Test::More;
use_ok 'PublicInbox::IMAP';
use_ok 'PublicInbox::IMAPD';
use PublicInbox::DS;
use Benchmark qw(:all);
my @n = map { { newsgroup => "inbox.comp.foo.bar.$_" } } (0..50000);
push @n, map { { newsgroup => "xobni.womp.foo.bar.$_" } } (0..50000);
my $self = { imapd => { grouplist => \@n } };
my $n = scalar @n;
my $t = timeit(1, sub {
	PublicInbox::IMAPD::refresh_inboxlist($self->{imapd});
});
diag timestr($t). "refresh $n inboxes";

open my $null, '>', '/dev/null' or BAIL_OUT "open: $!";
my $ds = { sock => $null };
my $nr = 200;
diag "starting benchmark...";
my $cmd_list = \&PublicInbox::IMAP::cmd_list;
$t = timeit(1, sub {
	for (0..$nr) {
		my $res = $cmd_list->($self, 'tag', '', '*');
		PublicInbox::DS::write($ds, $res);
	}
});
diag timestr($t). "list all for $n inboxes $nr times";
$nr = 20;
$t = timeit(1, sub {
	for (0..$nr) {
		my $res = $cmd_list->($self, 'tag', 'inbox.', '%');
		PublicInbox::DS::write($ds, $res);
	}
});
diag timestr($t). "list partial for $n inboxes $nr times";
done_testing;
