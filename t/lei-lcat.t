#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
require_mods(qw(lei));

test_lei(sub {
	my $in = "\nMessage-id: <qp\@example.com>\n";
	lei_ok([qw(lcat --stdin)], undef, { 0 => \$in, %$lei_opt });
	unlike($lei_out, qr/\S/, 'nothing, yet');
	lei_ok('import', 't/plack-qp.eml');
	lei_ok([qw(lcat --stdin)], undef, { 0 => \$in, %$lei_opt });
	like($lei_out, qr/qp\@example\.com/, 'got a result');

	# test Link:, -f reply, and implicit --stdin:
	my $prev = $lei_out;
	$in = "\nLink: https://example.com/foo/qp\@example.com/\n";
	lei_ok([qw(lcat -f reply)], undef, { 0 => \$in, %$lei_opt});
	my $exp = <<'EOM';
To: qp@example.com
Subject: Re: QP
In-Reply-To: <qp@example.com>

On some unknown date, qp wrote:
> hi = bye
EOM
	like($lei_out, qr/\AFrom [^\n]+\n\Q$exp\E/sm, '-f reply works');
});

done_testing;
