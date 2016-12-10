# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use_ok('PublicInbox::SearchMsg');
use_ok('PublicInbox::SearchThread');
use Email::Simple;
my $mt = eval {
	require Mail::Thread;
	no warnings 'once';
	$Mail::Thread::nosubject = 1;
	$Mail::Thread::noprune = 1;
};
my @check;
my @msgs = map {
	my $msg = $_;
	$msg->{references} =~ s/\s+/ /sg if $msg->{references};
	my $simple = Email::Simple->create(header => [
		'Message-Id' => "<$msg->{mid}>",
		'References' => $msg->{references},
	]);
	push @check, $simple;
	bless $msg, 'PublicInbox::SearchMsg'
} (

# data from t/testbox-6 in Mail::Thread 2.55:
	{ mid => '20021124145312.GA1759@nlin.net' },
	{ mid => 'slrnau448m.7l4.markj+0111@cloaked.freeserve.co.uk',
	  references => '<20021124145312.GA1759@nlin.net>',
	},
	{ mid => '15842.10677.577458.656565@jupiter.akutech-local.de',
	  references => '<20021124145312.GA1759@nlin.net>
			<slrnau448m.7l4.markj+0111@cloaked.freeserve.co.uk>',
	},
	{ mid => '20021125171807.GK8236@somanetworks.com',
	  references => '<20021124145312.GA1759@nlin.net>
			<slrnau448m.7l4.markj+0111@cloaked.freeserve.co.uk>
			<15842.10677.577458.656565@jupiter.akutech-local.de>',
	},
	{ mid => '15843.12163.554914.469248@jupiter.akutech-local.de',
	  references => '<20021124145312.GA1759@nlin.net>
			<slrnau448m.7l4.markj+0111@cloaked.freeserve.co.uk>
			<15842.10677.577458.656565@jupiter.akutech-local.de>
			<E18GPHf-0000zp-00@cloaked.freeserve.co.uk>',
	},
	{ mid => 'E18GPHf-0000zp-00@cloaked.freeserve.co.uk',
	  references => '<20021124145312.GA1759@nlin.net>
			<slrnau448m.7l4.markj+0111@cloaked.freeserve.co.uk>
			<15842.10677.577458.656565@jupiter.akutech-local.de>'
	}
);

my $st = thread_to_s(\@msgs);

SKIP: {
	skip 'Mail::Thread missing', 1 unless $mt;
	$mt = Mail::Thread->new(@check);
	$mt->thread;
	$mt->order(sub { sort { $a->messageid cmp $b->messageid } @_ });
	my $check = '';

	my @q = map { (0, $_) } $mt->rootset;
	while (@q) {
		my $level = shift @q;
		my $node = shift @q or next;
		$check .= (" "x$level) . $node->messageid . "\n";
		unshift @q, $level + 1, $node->child, $level, $node->next;
	}
	is($check, $st, 'Mail::Thread output matches');
}

done_testing();

sub thread_to_s {
	my $th = PublicInbox::SearchThread->new(shift);
	$th->thread;
	$th->order(sub { [ sort { $a->{id} cmp $b->{id} } @{$_[0]} ] });
	my $st = '';
	my @q = map { (0, $_) } @{$th->{rootset}};
	while (@q) {
		my $level = shift @q;
		my $node = shift @q or next;
		$st .= (" "x$level). "$node->{id}\n";
		my $cl = $level + 1;
		unshift @q, map { ($cl, $_) } @{$node->{children}};
	}
	$st;
}
