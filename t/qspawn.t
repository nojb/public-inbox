# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use v5.12;
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
	$qsp->{qsp_err} && ${$qsp->{qsp_err}};
}

my $limiter = PublicInbox::Qspawn::Limiter->new(1);
{
	my $x = PublicInbox::Qspawn->new([qw(true)]);
	$x->{qsp_err} = \(my $err = '');
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
	my @err; local $SIG{__WARN__} = sub { push @err, @_ };
	my $x = PublicInbox::Qspawn->new([qw(false)]);
	$x->{qsp_err} = \(my $err = '');
	my $run = 0;
	$x->start($limiter, sub {
		my ($self) = @_;
		is(0, sysread($self->{rpipe}, my $buf, 1),
				'read zero bytes from false');
		ok(finish_err($self), 'error on finish');
		$run = 1;
	});
	is($run, 1, 'callback ran alright');
	ok(scalar @err, 'got warning');
}

foreach my $cmd ([qw(sleep 1)], [qw(sh -c), 'sleep 1; false']) {
	my @err; local $SIG{__WARN__} = sub { push @err, @_ };
	my $s = PublicInbox::Qspawn->new($cmd);
	$s->{qsp_err} = \(my $err = '');
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
		ok(scalar @err, 'got warning');
	} else {
		ok(!finish_err($s), 'no error on sleep');
		is_deeply([], \@err, 'no warnings');
	}
	ok(!finish_err($_->[0]), "true $_->[1] succeeded") foreach @t;
	is_deeply([qw(sleep 0 1 2)], \@run, 'ran in order');
}

done_testing();

1;
