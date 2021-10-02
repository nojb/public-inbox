#!perl -w
# Copyright all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;

test_lei(sub {
	my ($ro_home, $cfg_path) = setup_public_inboxes;
	lei_ok qw(inspect --dir), "$ro_home/t1", 'mid:testmessage@example.com';
	my $ent = json_utf8->decode($lei_out);
	is(ref($ent->{smsg}), 'ARRAY', 'smsg array');
	is(ref($ent->{xdoc}), 'ARRAY', 'xdoc array');
});

done_testing;
