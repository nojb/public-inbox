#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
use Sys::Hostname qw(hostname);
use POSIX qw(strftime);
use PublicInbox::OnDestroy;
use PublicInbox::URIimap;
use PublicInbox::Config;
my $imap_url = $ENV{TEST_IMAP_WRITE_URL} or
	plan skip_all => 'TEST_IMAP_WRITE_URL unset';
my $uri = PublicInbox::URIimap->new($imap_url);
defined($uri->path) and
	plan skip_all => "$imap_url should not be a mailbox (just host:port)";
require_mods('Mail::IMAPClient');
require_ok 'PublicInbox::NetWriter';
my $host = (split(/\./, hostname))[0];
my ($base) = ($0 =~ m!\b([^/]+)\.[^\.]+\z!);
my $folder = "INBOX.$base-$host-".strftime('%Y%m%d%H%M%S', gmtime(time)).
		"-$$-".sprintf('%x', int(rand(0xffffffff)));
my $nwr = PublicInbox::NetWriter->new;
$imap_url .= '/' unless substr($imap_url, -1) eq '/';
my $folder_uri = PublicInbox::URIimap->new("$imap_url/$folder");
is($folder_uri->mailbox, $folder, 'folder correct') or
		BAIL_OUT "BUG: bad $$uri";
$nwr->add_url($$folder_uri);
is($nwr->errors, undef, 'no errors');
$nwr->{pi_cfg} = bless {}, 'PublicInbox::Config';
my $mics = $nwr->imap_common_init;
my $mic = (values %$mics)[0];
my $cleanup = PublicInbox::OnDestroy->new(sub {
	$mic->delete($folder) or fail "delete $folder <$folder_uri>: $@";
});
my $imap_append = $nwr->can('imap_append');
my $smsg = bless { kw => [ 'seen' ] }, 'PublicInbox::Smsg';
$imap_append->($mic, $folder, undef, $smsg, eml_load('t/plack-qp.eml'));
my @res;
$nwr->{quiet} = 1;
$nwr->imap_each($$folder_uri, sub {
	my ($u, $uid, $kw, $eml, $arg) = @_;
	push @res, [ $kw, $eml ];
});
is(scalar(@res), 1, 'got appended message');
is_deeply(\@res, [ [ [ 'seen' ], eml_load('t/plack-qp.eml') ] ],
	'uploaded message read back');

undef $cleanup;
done_testing;
