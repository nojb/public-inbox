# Copyright (C) 2016-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::MIME;
use_ok 'PublicInbox::Filter::Vger';

my $f = PublicInbox::Filter::Vger->new;
ok($f, 'created PublicInbox::Filter::Vger object');
{
	my $lkml = <<'EOF';
From: foo@example.com
Subject: test

keep this
--
To unsubscribe from this list: send the line "unsubscribe linux-kernel" in
the body of a message to majordomo@vger.kernel.org
More majordomo info at  http://vger.kernel.org/majordomo-info.html
Please read the FAQ at  http://www.tux.org/lkml/
EOF

	my $mime = PublicInbox::MIME->new($lkml);
	$mime = $f->delivery($mime);
	is("keep this\n", $mime->body, 'normal message filtered OK');
}

{
	my $no_nl = <<'EOF';
From: foo@example.com
Subject: test

OSX users :P--
To unsubscribe from this list: send the line "unsubscribe git" in
the body of a message to majordomo@vger.kernel.org
More majordomo info at  http://vger.kernel.org/majordomo-info.html
EOF

	my $mime = PublicInbox::MIME->new($no_nl);
	$mime = $f->delivery($mime);
	is('OSX users :P', $mime->body, 'missing trailing LF in original OK');
}


done_testing();
