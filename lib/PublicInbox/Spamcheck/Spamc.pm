# Copyright (C) 2016-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Default spam filter class for wrapping spamc(1)
package PublicInbox::Spamcheck::Spamc;
use strict;
use warnings;
use PublicInbox::Spawn qw(popen_rd spawn);
use IO::Handle;
use Fcntl qw(SEEK_SET);

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

	my $rdr = { 0 => _msg_to_fh($self, $msg) };
	my ($fh, $pid) = popen_rd($self->{checkcmd}, undef, $rdr);
	unless (ref $out) {
		my $buf = '';
		$out = \$buf;
	}
	$$out = do { local $/; <$fh> };
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
	$rdr->{0} = _msg_to_fh($self, $msg);
	$rdr->{1} ||= $self->_devnull;
	$rdr->{2} ||= $self->_devnull;
	my $pid = spawn($self->{$field}, undef, $rdr);
	waitpid($pid, 0);
	!$?;
}

sub _devnull {
	my ($self) = @_;
	$self->{-devnull} //= do {
		open my $fh, '+>', '/dev/null' or
				die "failed to open /dev/null: $!";
		$fh
	}
}

sub _msg_to_fh {
	my ($self, $msg) = @_;
	if (my $ref = ref($msg)) {
		my $fd = eval { fileno($msg) };
		return $msg if defined($fd) && $fd >= 0;

		open(my $tmpfh, '+>', undef) or die "failed to open: $!";
		$tmpfh->autoflush(1);
		$msg = \($msg->as_string) if $ref ne 'SCALAR';
		print $tmpfh $$msg or die "failed to print: $!";
		sysseek($tmpfh, 0, SEEK_SET) or
			die "sysseek(fh) failed: $!";

		return $tmpfh;
	}
	$msg;
}

1;
