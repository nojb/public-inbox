# Copyright (C) 2016-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use Email::MIME;
use_ok('PublicInbox::MsgIter');

{
	my $parts = [ Email::MIME->create(body => "a\n"),
			Email::MIME->create(body => "b\n") ];
	my $mime = Email::MIME->create(parts => $parts,
				header_str => [ From => 'root@localhost' ]);
	my @parts;
	msg_iter($mime, sub {
		my ($part, $level, @ex) = @{$_[0]};
		my $s = $part->body_str;
		$s =~ s/\s+//s;
		push @parts, [ $s, $level, @ex ];
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
		my $s = $part->body_str;
		$s =~ s/\s+//s;
		push @parts, [ $s, $level, @ex ];
	});
	is_deeply(\@parts, [ [qw(a 2 1 1)], [qw(b 2 1 2)], [qw(sig 1 2)] ],
		'nested part shows up properly');
}

{
	my $f = 't/iso-2202-jp.mbox';
	my $mime = Email::MIME->new(do {
		open my $fh, '<', $f or die "open($f): $!";
		local $/;
		<$fh>;
	});
	my $raw = '';
	msg_iter($mime, sub {
		my ($part, $level, @ex) = @{$_[0]};
		my ($s, $err) = msg_part_text($part, 'text/plain');
		ok(!$err, 'no error');
		$raw .= $s;
	});
	ok(length($raw) > 0, 'got non-empty message');
	is(index($raw, '$$$'), -1, 'no unescaped $$$');
}

done_testing();
1;
