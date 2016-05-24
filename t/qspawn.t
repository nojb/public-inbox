# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use Test::More;
use_ok 'PublicInbox::Qspawn';
{
	my $x = PublicInbox::Qspawn->new([qw(true)]);
	my $run = 0;
	$x->start(sub {
		my ($rpipe) = @_;
		is(0, sysread($rpipe, my $buf, 1), 'read zero bytes');
		ok(!$x->finish, 'no error on finish');
		$run = 1;
	});
	is($run, 1, 'callback ran alright');
}

{
	my $x = PublicInbox::Qspawn->new([qw(false)]);
	my $run = 0;
	$x->start(sub {
		my ($rpipe) = @_;
		is(0, sysread($rpipe, my $buf, 1), 'read zero bytes from false');
		my $err = $x->finish;
		is($err, 256, 'error on finish');
		$run = 1;
	});
	is($run, 1, 'callback ran alright');
}

foreach my $cmd ([qw(sleep 1)], [qw(sh -c), 'sleep 1; false']) {
	my $s = PublicInbox::Qspawn->new($cmd);
	my @run;
	$s->start(sub {
		my ($rpipe) = @_;
		push @run, 'sleep';
		is(0, sysread($rpipe, my $buf, 1), 'read zero bytes');
	});
	my $n = 0;
	my @t = map {
		my $i = $n++;
		my $x = PublicInbox::Qspawn->new([qw(true)]);
		$x->start(sub {
			my ($rpipe) = @_;
			push @run, $i;
		});
		[$x, $i]
	} (0..2);

	if ($cmd->[-1] =~ /false\z/) {
		ok($s->finish, 'got error on false after sleep');
	} else {
		ok(!$s->finish, 'no error on sleep');
	}
	ok(!$_->[0]->finish, "true $_->[1] succeeded") foreach @t;
	is_deeply([qw(sleep 0 1 2)], \@run, 'ran in order');
}

done_testing();

1;
