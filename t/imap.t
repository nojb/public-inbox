#!perl -w
# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# unit tests (no network) for IMAP, see t/imapd.t for end-to-end tests
use strict;
use Test::More;
use PublicInbox::TestCommon;
require_mods(qw(DBD::SQLite Email::Address::XS||Mail::Address
	Parse::RecDescent));
require_ok 'PublicInbox::IMAP';
require_ok 'PublicInbox::IMAPD';
require_git 2.6;

my ($tmpdir, $for_destroy) = tmpdir();
my $cfgfile = "$tmpdir/config";
{
	open my $fh, '>', $cfgfile or BAIL_OUT $!;
	print $fh <<EOF or BAIL_OUT $!;
[publicinbox "a"]
	inboxdir = $tmpdir/a
	newsgroup = x.y.z
[publicinbox "b"]
	inboxdir = $tmpdir/b
	newsgroup = x.z.y
[publicinbox "c"]
	inboxdir = $tmpdir/c
	newsgroup = IGNORE.THIS
EOF
	close $fh or BAIL_OUT $!;
	local $ENV{PI_CONFIG} = $cfgfile;
	for my $x (qw(a b c)) {
		ok(run_script(['-init', '-Lbasic', '-V2', $x, "$tmpdir/$x",
				"https://example.com/$x", "$x\@example.com"]),
			"init $x");
	}
	my $imapd = PublicInbox::IMAPD->new;
	my @w;
	local $SIG{__WARN__} = sub { push @w, @_ };
	$imapd->refresh_groups;
	my $self = { imapd => $imapd };
	is(scalar(@w), 1, 'got a warning for upper-case');
	like($w[0], qr/IGNORE\.THIS/, 'warned about upper-case');
	my $res = PublicInbox::IMAP::cmd_list($self, 'tag', 'x', '%');
	is(scalar($$res =~ tr/\n/\n/), 2, 'only one result');
	like($$res, qr/ x\r\ntag OK/, 'saw expected');
	$res = PublicInbox::IMAP::cmd_list($self, 'tag', 'x.', '%');
	is(scalar($$res =~ tr/\n/\n/), 3, 'only one result');
	is(scalar(my @x = ($$res =~ m/ x\.[zy]\r\n/g)), 2, 'match expected');

	$res = PublicInbox::IMAP::cmd_list($self, 't', 'x.(?{die "RCE"})', '%');
	like($$res, qr/\At OK /, 'refname does not match attempted RCE');
	$res = PublicInbox::IMAP::cmd_list($self, 't', '', '(?{die "RCE"})%');
	like($$res, qr/\At OK /, 'wildcard does not match attempted RCE');
}

{
	my $partial_prepare = \&PublicInbox::IMAP::partial_prepare;
	my $x = {};
	my $n = 0;
	my $r = $partial_prepare->(\$n, $x, [], my $p = 'BODY[9]');
	ok($r, $p);
	$r = $partial_prepare->(\$n, $x, [], $p = 'BODY[9]<5>');
	ok($r, $p);
	$r = $partial_prepare->(\$n, $x, [], $p = 'BODY[9]<5.1>');
	ok($r, $p);
	$r = $partial_prepare->(\$n, $x, [], $p = 'BODY[1.1]');
	ok($r, $p);
	$r = $partial_prepare->(\$n, $x, [],
				$p = 'BODY[HEADER.FIELDS (DATE FROM)]');
	ok($r, $p);
	$r = $partial_prepare->(\$n, $x, [],
				$p = 'BODY[HEADER.FIELDS.NOT (TO)]');
	ok($r, $p);
	$r = $partial_prepare->(\$n, $x, [],
				$p = 'BODY[HEDDER.FIELDS.NOT (TO)]');
	ok(!$r, "rejected misspelling $p");
	$r = $partial_prepare->(\$n, $x, [],
				$p = 'BODY[1.1.HEADER.FIELDS (TO)]');
	ok($r, $p);
	my $partial_body = \&PublicInbox::IMAP::partial_body;
	my $partial_hdr_get = \&PublicInbox::IMAP::partial_hdr_get;
	my $partial_hdr_not = \&PublicInbox::IMAP::partial_hdr_not;
	my $hdrs_regexp = \&PublicInbox::IMAP::hdrs_regexp;
	is_deeply($x, {
		'BODY[9]' => [ $partial_body, 9, undef, undef, undef ],
		'BODY[9]<5>' => [ $partial_body, 9, undef, 5, undef ],
		'BODY[9]<5.1>' => [ $partial_body, 9, undef, 5, 1 ],
		'BODY[1.1]' => [ $partial_body, '1.1', undef, undef, undef ],
		'BODY[HEADER.FIELDS (DATE FROM)]' => [ $partial_hdr_get,
					undef, $hdrs_regexp->('DATE FROM'),
					undef, undef ],
		'BODY[HEADER.FIELDS.NOT (TO)]' => [ $partial_hdr_not,
						undef, $hdrs_regexp->('TO'),
						undef, undef ],
		'BODY[1.1.HEADER.FIELDS (TO)]' => [ $partial_hdr_get,
						'1.1', $hdrs_regexp->('TO'),
						undef, undef ],
	}, 'structure matches expected');
}

{
	my $fetch_compile = \&PublicInbox::IMAP::fetch_compile;
	my ($cb, $ops, $partial) = $fetch_compile->(['BODY[]']);
	is($partial, undef, 'no partial fetch data');
	is_deeply($ops, [
		undef, \&PublicInbox::IMAP::op_crlf_bref,
		'BODY[]', \&PublicInbox::IMAP::emit_rfc822
	], 'proper key and op compiled for BODY[]');

	($cb, $ops, $partial) = $fetch_compile->(['BODY', 'BODY[]']);
	is_deeply($ops, [
		undef, \&PublicInbox::IMAP::op_crlf_bref,
		'BODY[]', \&PublicInbox::IMAP::emit_rfc822,
		undef, \&PublicInbox::IMAP::op_eml_new,
		'BODY', \&PublicInbox::IMAP::emit_body,
	], 'placed op_eml_new before emit_body');
}

# UID <=> MSN mapping

sub uo2m_str_new ($) {
	no warnings 'uninitialized'; # uom2m_ary_new may have may have undef
	pack('S*', @{$_[0]->uo2m_ary_new}); # 2 bytes per-MSN
}

{
	my $ibx = bless { uid_range => [ 1, 2, 4 ] }, 'Uo2mTestInbox';
	my $imap = bless { uid_base => 0, ibx => $ibx }, 'PublicInbox::IMAP';
	my $uo2m = $imap->uo2m_ary_new;
	is_deeply($uo2m, [ 1, 2, undef, 3 ], 'uo2m ary');
	$uo2m = uo2m_str_new($imap);
	is_deeply([ unpack('S*', $uo2m) ], [ 1, 2, 0, 3 ], 'uo2m str');

	$ibx->{uid_range} = [ 1, 2, 4, 5, 6 ];
	for ([ 1, 2, undef, 3 ], $uo2m) {
		$imap->{uo2m} = $_;
		is($imap->uid2msn(1), 1, 'uid2msn');
		is($imap->uid2msn(4), 3, 'uid2msn');
		is($imap->uo2m_last_uid, 4, 'uo2m_last_uid');
		$imap->uo2m_extend(6);
		is($imap->uid2msn(5), 4, 'uid2msn 5 => 4');
		is($imap->uid2msn(6), 5, 'uid2msn 6 => 5');
		is($imap->uo2m_last_uid, 6, 'uo2m_last_uid');

		my $msn2uid = $imap->msn2uid;
		my $range = '1,4:5';
		$imap->can('msn_to_uid_range')->($msn2uid, $range);
		is($range, '1,5:6', 'range converted');
	}
}

done_testing;

package Uo2mTestInbox;
use strict;
require PublicInbox::DummyInbox;
our @ISA = qw(PublicInbox::DummyInbox);
sub over { shift }
sub uid_range {
	my ($self, $beg, $end, undef) = @_;
	[ grep { $_ >= $beg && $_ <= $end } @{$self->{uid_range}} ];
}
