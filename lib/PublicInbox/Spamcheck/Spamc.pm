# Copyright (C) 2016-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Default spam filter class for wrapping spamc(1)
package PublicInbox::Spamcheck::Spamc;
use strict;
use warnings;
use PublicInbox::Spawn qw(popen_rd spawn);
use IO::Handle;
use Fcntl qw(:DEFAULT SEEK_SET);

sub new {
	my ($class) = @_;
	bless {
		checkcmd => [qw(spamc -E --headers)],
		hamcmd => [qw(spamc -L ham)],
		spamcmd => [qw(spamc -L spam)],
	}, $class;
}

sub spamcheck {
	my ($self, $msg, $out) = @_;

	my $tmp;
	my $fd = _msg_to_fd($self, $msg, \$tmp);
	my $rdr = { 0 => $fd };
	my ($fh, $pid) = popen_rd($self->{checkcmd}, undef, $rdr);
	defined $pid or die "failed to popen_rd spamc: $!\n";
	my $r;
	unless (ref $out) {
		my $buf = '';
		$out = \$buf;
	}
again:
	do {
		$r = sysread($fh, $$out, 65536, length($$out));
	} while (defined($r) && $r != 0);
	unless (defined $r) {
		goto again if $!{EINTR};
		die "read failed: $!";
	}
	close $fh or die "close failed: $!";
	waitpid($pid, 0);
	($? || $$out eq '') ? 0 : 1;
}

sub hamlearn {
	my ($self, $msg, $rdr) = @_;
	_learn($self, $msg, $rdr, 'hamcmd');
}

sub spamlearn {
	my ($self, $msg, $rdr) = @_;
	_learn($self, $msg, $rdr, 'spamcmd');
}

sub _learn {
	my ($self, $msg, $rdr, $field) = @_;
	$rdr ||= {};
	$rdr->{1} ||= $self->_devnull;
	$rdr->{2} ||= $self->_devnull;
	my $tmp;
	$rdr->{0} = _msg_to_fd($self, $msg, \$tmp);
	my $pid = spawn($self->{$field}, undef, $rdr);
	waitpid($pid, 0);
	!$?;
}

sub _devnull {
	my ($self) = @_;
	my $fd = $self->{-devnullfd};
	return $fd if defined $fd;
	open my $fh, '+>', '/dev/null' or
				die "failed to open /dev/null: $!";
	$self->{-devnull} = $fh;
	$self->{-devnullfd} = fileno($fh);
}

sub _msg_to_fd {
	my ($self, $msg, $tmpref) = @_;
	my $fd;
	if (my $ref = ref($msg)) {
		my $fileno = eval { fileno($msg) };
		return $fileno if defined $fileno;

		open(my $tmpfh, '+>', undef) or die "failed to open: $!";
		$tmpfh->autoflush(1);
		$msg = \($msg->as_string) if $ref ne 'SCALAR';
		print $tmpfh $$msg or die "failed to print: $!";
		sysseek($tmpfh, 0, SEEK_SET) or
			die "sysseek(fh) failed: $!";
		$$tmpref = $tmpfh;

		return fileno($tmpfh);
	}
	$msg;
}

1;
