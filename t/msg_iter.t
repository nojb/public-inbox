# Copyright (C) 2016-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use Email::MIME;
use PublicInbox::Hval qw(ascii_html);
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

{
	my $f = 't/x-unknown-alpine.eml';
	my $mime = Email::MIME->new(do {
		open my $fh, '<', $f or die "open($f): $!";
		local $/;
		binmode $fh;
		<$fh>;
	});
	my $raw = '';
	msg_iter($mime, sub {
		my ($part, $level, @ex) = @{$_[0]};
		my ($s, $err) = msg_part_text($part, 'text/plain');
		$raw .= $s;
	});
	like($raw, qr!^\thttps://!ms, 'tab expanded with X-UNKNOWN');
	like(ascii_html($raw), qr/&#8226; bullet point/s,
		'got bullet point when X-UNKNOWN assumes UTF-8');
}

{ # API not finalized
	my @warn;
	local $SIG{__WARN__} = sub { push @warn, [ @_ ] };
	my $attr = "So and so wrote:\n";
	my $q = "> hello world\n" x 10;
	my $nq = "hello world\n" x 10;
	my @sections = PublicInbox::MsgIter::split_quotes($attr . $q . $nq);
	is($sections[0], $attr, 'attribution matches');
	is($sections[1], $q, 'quoted section matches');
	is($sections[2], $nq, 'non-quoted section matches');
	is(scalar(@sections), 3, 'only three sections for short message');
	is_deeply(\@warn, [], 'no warnings');

	$q x= 3300;
	$nq x= 3300;
	@sections = PublicInbox::MsgIter::split_quotes($attr . $q . $nq);
	is_deeply(\@warn, [], 'no warnings on giant message');
	is(join('', @sections), $attr . $q . $nq, 'result matches expected');
	is(shift(@sections), $attr, 'attribution is first section');
	my @check = ('', '');
	while (defined(my $l = shift @sections)) {
		next if $l eq '';
		like($l, qr/\n\z/s, 'section ends with newline');
		my $idx = ($l =~ /\A>/) ? 0 : 1;
		$check[$idx] .= $l;
	}
	is($check[0], $q, 'long quoted section matches');
	is($check[1], $nq, 'long quoted section matches');
}

done_testing();
1;
