# Copyright (C) 2016-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
use_ok('PublicInbox::SearchThread');
my $mt = eval {
	require Mail::Thread;
	no warnings 'once';
	$Mail::Thread::nosubject = 1;
	$Mail::Thread::noprune = 1;
	require Email::Simple; # required by Mail::Thread (via Email::Abstract)
};

my $make_objs = sub {
	my @simples;
	my $n = 0;
	my @msgs = map {
		my $msg = $_;
		$msg->{ds} ||= ++$n;
		$msg->{references} =~ s/\s+/ /sg if $msg->{references};
		$msg->{blob} = '0'x40; # any dummy value will do, here
		if ($mt) {
			my $simple = Email::Simple->create(header => [
				'Message-ID' => "<$msg->{mid}>",
				'References' => $msg->{references},
			]);
			push @simples, $simple;
		}
		bless $msg, 'PublicInbox::Smsg'
	} @_;
	(\@simples, \@msgs);
};

my ($simples, $smsgs) = $make_objs->(
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

my $st = thread_to_s($smsgs);

SKIP: {
	skip 'Mail::Thread missing', 1 unless $mt;
	check_mt($st, $simples, 'Mail::Thread output matches');
}

my @backwards = (
	{ mid => 1, references => '<2> <3> <4>' },
	{ mid => 4, references => '<2> <3>' },
	{ mid => 5, references => '<6> <7> <8> <3> <2>' },
	{ mid => 9, references => '<6> <3>' },
	{ mid => 10, references => '<8> <7> <6>' },
	{ mid => 2, references => '<6> <7> <8> <3>' },
	{ mid => 3, references => '<6> <7> <8>' },
	{ mid => 6, references => '<8> <7>' },
	{ mid => 7, references => '<8>' },
	{ mid => 8, references => '' }
);

($simples, $smsgs) = $make_objs->(@backwards);
my $backward = thread_to_s($smsgs);
SKIP: {
	skip 'Mail::Thread missing', 1 unless $mt;
	check_mt($backward, $simples, 'matches Mail::Thread backwards');
}
($simples, $smsgs) = $make_objs->(reverse @backwards);
my $forward = thread_to_s($smsgs);
unless ('Mail::Thread sorts by Date') {
	SKIP: {
		skip 'Mail::Thread missing', 1 unless $mt;
		check_mt($forward, $simples, 'matches Mail::Thread forwards');
	}
}
if ('sorting by Date') {
	is("\n".$backward, "\n".$forward, 'forward and backward matches');
}

done_testing();

sub thread_to_s {
	my ($msgs) = @_;
	my $rootset = PublicInbox::SearchThread::thread($msgs, sub {
		[ sort { $a->{mid} cmp $b->{mid} } @{$_[0]} ] });
	my $st = '';
	my @q = map { (0, $_) } @$rootset;
	while (@q) {
		my $level = shift @q;
		my $node = shift @q or next;
		$st .= (" "x$level). "$node->{mid}\n";
		my $cl = $level + 1;
		unshift @q, map { ($cl, $_) } @{$node->{children}};
	}
	$st;
}

sub check_mt {
	my ($st, $simples, $msg) = @_;
	my $mt = Mail::Thread->new(@$simples);
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
	is("\n".$check, "\n".$st, $msg);
}
