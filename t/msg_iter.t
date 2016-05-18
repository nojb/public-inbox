# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use Email::MIME;
use_ok('PublicInbox::MsgIter');

{
	my $parts = [ Email::MIME->create(body => 'a'),
			Email::MIME->create(body => 'b') ];
	my $mime = Email::MIME->create(parts => $parts,
				header_str => [ From => 'root@localhost' ]);
	my @parts;
	msg_iter($mime, sub {
		my ($part, $level, @ex) = @{$_[0]};
		push @parts, [ $part->body_str, $level, @ex ];
	});
	is_deeply(\@parts, [ [ qw(a 1 1) ], [ qw(b 1 2) ] ], 'order is fine');
}

{
	my $parts = [ Email::MIME->create(body => 'a'),
			Email::MIME->create(body => 'b') ];
	$parts = [ Email::MIME->create(parts => $parts,
				header_str => [ From => 'sub@localhost' ]),
			Email::MIME->create(body => 'sig') ];
	my $mime = Email::MIME->create(parts => $parts,
				header_str => [ From => 'root@localhost' ]);
	my @parts;
	msg_iter($mime, sub {
		my ($part, $level, @ex) = @{$_[0]};
		push @parts, [ $part->body_str, $level, @ex ];
	});
	is_deeply(\@parts, [ [ qw(a 2 1 1)], [qw(b 2 1 2)], [qw(sig 1 2)] ],
		'nested part shows up properly');
}

done_testing();
1;
