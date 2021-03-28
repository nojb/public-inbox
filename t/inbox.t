# Copyright (C) 2016-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use_ok 'PublicInbox::Inbox';
use File::Temp 0.19 ();
my $x = PublicInbox::Inbox->new({url => [ '//example.com/test/' ]});
is($x->base_url, 'https://example.com/test/', 'expanded protocol-relative');
$x = PublicInbox::Inbox->new({url => [ 'http://example.com/test' ]});
is($x->base_url, 'http://example.com/test/', 'added trailing slash');

$x = PublicInbox::Inbox->new({});

is($x->base_url, undef, 'undef base_url allowed');
my $tmpdir = File::Temp->newdir('pi-inbox-XXXX', TMPDIR => 1);
$x->{inboxdir} = $tmpdir->dirname;
is_deeply($x->cloneurl, [], 'no cloneurls');
is($x->description, '($INBOX_DIR/description missing)', 'default description');
{
	open my $fh, '>', "$x->{inboxdir}/cloneurl" or die;
	print $fh "https://example.com/inbox\n" or die;
	close $fh or die;
	open $fh, '>', "$x->{inboxdir}/description" or die;
	print $fh "\xc4\x80blah\n" or die;
	close $fh or die;
}
is_deeply($x->cloneurl, ['https://example.com/inbox'], 'cloneurls update');
ok(utf8::valid($x->description), 'description is utf8::valid');
is($x->description, "\x{100}blah", 'description updated');
is(unlink(glob("$x->{inboxdir}/*")), 2, 'unlinked cloneurl & description');
is_deeply($x->cloneurl, ['https://example.com/inbox'], 'cloneurls memoized');
is($x->description, "\x{100}blah", 'description memoized');

$x->{name} = "2\x{100}wide";
$x->{newsgroup} = '2.wide';
like($x->mailboxid, qr/\AM32c48077696465-[0-9a-f]+\z/,
	'->mailboxid w/o slice (JMAP)');
like($x->mailboxid(78), qr/\AM322e77696465-4e-[0-9a-f]+\z/,
	'->mailboxid w/ slice (IMAP)');

done_testing();
