# Copyright (C) 2016-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use Test::More;
use_ok 'PublicInbox::Qspawn';

{
	my $cmd = [qw(sh -c), 'echo >&2 err; echo out'];
	my $qsp = PublicInbox::Qspawn->new($cmd, {}, { 2 => 1 });
	my $res;
	$qsp->psgi_qx({}, undef, sub { $res = ${$_[0]} });
	is($res, "err\nout\n", 'captured stderr and stdout');

	$res = undef;
	$qsp = PublicInbox::Qspawn->new($cmd, {}, { 2 => \*STDOUT });
	$qsp->psgi_qx({}, undef, sub { $res = ${$_[0]} });
	is($res, "err\nout\n", 'captured stderr and stdout');
}

sub finish_err ($) {
	my ($qsp) = @_;
	$qsp->finish;
	$qsp->{err};
}

my $limiter = PublicInbox::Qspawn::Limiter->new(1);
{
	my $x = PublicInbox::Qspawn->new([qw(true)]);
	my $run = 0;
	$x->start($limiter, sub {
		my ($self) = @_;
		is(0, sysread($self->{rpipe}, my $buf, 1), 'read zero bytes');
		ok(!finish_err($self), 'no error on finish');
		$run = 1;
	});
	is($run, 1, 'callback ran alright');
}

{
	my $x = PublicInbox::Qspawn->new([qw(false)]);
	my $run = 0;
	$x->start($limiter, sub {
		my ($self) = @_;
		is(0, sysread($self->{rpipe}, my $buf, 1),
				'read zero bytes from false');
		ok(finish_err($self), 'error on finish');
		$run = 1;
	});
	is($run, 1, 'callback ran alright');
}

foreach my $cmd ([qw(sleep 1)], [qw(sh -c), 'sleep 1; false']) {
	my $s = PublicInbox::Qspawn->new($cmd);
	my @run;
	$s->start($limiter, sub {
		my ($self) = @_;
		push @run, 'sleep';
		is(0, sysread($self->{rpipe}, my $buf, 1), 'read zero bytes');
	});
	my $n = 0;
	my @t = map {
		my $i = $n++;
		my $x = PublicInbox::Qspawn->new([qw(true)]);
		$x->start($limiter, sub {
			my ($self) = @_;
			push @run, $i;
		});
		[$x, $i]
	} (0..2);

	if ($cmd->[-1] =~ /false\z/) {
		ok(finish_err($s), 'got error on false after sleep');
	} else {
		ok(!finish_err($s), 'no error on sleep');
	}
	ok(!finish_err($_->[0]), "true $_->[1] succeeded") foreach @t;
	is_deeply([qw(sleep 0 1 2)], \@run, 'ran in order');
}

done_testing();

1;
