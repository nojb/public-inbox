#!/usr/bin/perl -w
# Copyright (C) 2016-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# Parallel WWW checker
my $usage = "$0 [-j JOBS] [-s SLOW_THRESHOLD] URL_OF_INBOX\n";
use strict;
use warnings;
use File::Temp qw(tempfile);
use GDBM_File;
use Getopt::Long qw(:config gnu_getopt no_ignore_case auto_abbrev);
use IO::Socket;
use LWP::ConnCache;
use POSIX qw(:sys_wait_h);
use Time::HiRes qw(gettimeofday tv_interval);
use WWW::Mechanize;
use Data::Dumper;

# we want to use vfork+exec with spawn, WWW::Mechanize can use too much
# memory and fork(2) fails
use PublicInbox::Spawn qw(spawn which);
$ENV{PERL_INLINE_DIRECTORY} or warn "PERL_INLINE_DIRECTORY unset, may OOM\n";

our $tmp_owner = $$;
my $nproc = 4;
my $slow = 0.5;
my %opts = (
	'-j|jobs=i' => \$nproc,
	'-s|slow-threshold=f' => \$slow,
);
GetOptions(%opts) or die "bad command-line args\n$usage";
my $root_url = shift or die $usage;

chomp(my $xmlstarlet = which('xmlstarlet'));
my $atom_check = eval {
	my $cmd = [ qw(xmlstarlet val -e -) ];
	sub {
		my ($in, $out, $err) = @_;
		use autodie;
		open my $in_fh, '+>', undef;
		open my $out_fh, '+>', undef;
		open my $err_fh, '+>', undef;
		print $in_fh $$in;
		$in_fh->flush;
		sysseek($in_fh, 0, 0);
		my $rdr = {
			0 => fileno($in_fh),
			1 => fileno($out_fh),
			2 => fileno($err_fh),
		};
		my $pid = spawn($cmd, undef, $rdr);
		while (waitpid($pid, 0) != $pid) {
			next if $!{EINTR};
			warn "waitpid(xmlstarlet, $pid) $!";
			return $!;
		}
		sysseek($out_fh, 0, 0);
		sysread($out_fh, $$out, -s $out_fh);
		sysseek($err_fh, 0, 0);
		sysread($err_fh, $$err, -s $err_fh);
		$?
	}
} if $xmlstarlet;

my %workers;
$SIG{INT} = sub { exit 130 };
$SIG{TERM} = sub { exit 0 };
$SIG{CHLD} = sub {
	while (1) {
		my $pid = waitpid(-1, WNOHANG);
		return if !defined $pid || $pid <= 0;
		my $p = delete $workers{$pid} || '(unknown)';
		warn("$pid [$p] exited with $?\n") if $?;
	}
};

my @todo = IO::Socket->socketpair(AF_UNIX, SOCK_SEQPACKET, 0);
die "socketpair failed: $!" unless $todo[1];
my @done = IO::Socket->socketpair(AF_UNIX, SOCK_SEQPACKET, 0);
die "socketpair failed: $!" unless $done[1];
$| = 1;

foreach my $p (1..$nproc) {
	my $pid = fork;
	die "fork failed: $!\n" unless defined $pid;
	if ($pid) {
		$workers{$pid} = $p;
	} else {
		$todo[1]->close;
		$done[0]->close;
		worker_loop($todo[0], $done[1]);
	}
}

my ($fh, $tmp) = tempfile('www-check-XXXXXXXX',
			SUFFIX => '.gdbm', UNLINK => 1, TMPDIR => 1);
my $gdbm = tie my %seen, 'GDBM_File', $tmp, &GDBM_WRCREAT, 0600;
defined $gdbm or die "gdbm open failed: $!\n";
$todo[0]->close;
$done[1]->close;

my ($rvec, $wvec);
$todo[1]->blocking(0);
$done[0]->blocking(0);
$seen{$root_url} = 1;
my $ndone = 0;
my $nsent = 1;
my @queue = ($root_url);
my $timeout = $slow * 4;
while (keys %workers) { # reacts to SIGCHLD
	$wvec = $rvec = '';
	my $u;
	vec($rvec, fileno($done[0]), 1) = 1;
	if (@queue) {
		vec($wvec, fileno($todo[1]), 1) = 1;
	} elsif ($ndone == $nsent) {
		kill 'TERM', keys %workers;
		exit;
	}
	if (!select($rvec, $wvec, undef, $timeout)) {
		while (my ($k, $v) = each %seen) {
			next if $v == 2;
			print "WAIT ($ndone/$nsent) <$k>\n";
		}
	}
	while ($u = shift @queue) {
		my $s = $todo[1]->send($u, MSG_EOR);
		if ($!{EAGAIN}) {
			unshift @queue, $u;
			last;
		}
	}
	my $r;
	do {
		$r = $done[0]->recv($u, 65535, 0);
	} while (!defined $r && $!{EINTR});
	next unless $u;
	if ($u =~ s/\ADONE\t//) {
		$ndone++;
		$seen{$u} = 2;
	} else {
		next if $seen{$u};
		$seen{$u} = 1;
		$nsent++;
		push @queue, $u;
	}
}

sub worker_loop {
	my ($todo_rd, $done_wr) = @_;
	$SIG{CHLD} = 'DEFAULT';
	my $m = WWW::Mechanize->new(autocheck => 0);
	my $cc = LWP::ConnCache->new;
	$m->stack_depth(0); # no history
	$m->conn_cache($cc);
	while (1) {
		$todo_rd->recv(my $u, 65535, 0);
		next unless $u;

		my $t = [ gettimeofday ];
		my $r = $m->get($u);
		$t = tv_interval($t);
		printf "SLOW %0.06f % 5d %s\n", $t, $$, $u if $t > $slow;
		my @links;
		if ($r->is_success) {
			my %links = map {
				(split('#', $_->URI->abs->as_string))[0] => 1;
			} grep {
				$_->tag && $_->url !~ /:/
			} $m->links;
			@links = keys %links;
		} elsif ($r->code != 300) {
			warn "W: ".$r->code . " $u\n"
		}

		my $s;
		# blocking
		foreach my $l (@links, "DONE\t$u") {
			next if $l eq '' || $l =~ /\.mbox(?:\.gz)\z/;
			do {
				$s = $done_wr->send($l, MSG_EOR);
			} while (!defined $s && $!{EINTR});
			die "$$ send $!\n" unless defined $s;
			my $n = length($l);
			die "$$ send truncated $s < $n\n" if $s != $n;
		}

		# make sure the HTML source doesn't screw up terminals
		# when people curl the source (not remotely an expert
		# on languages or encodings, here).
		my $ct = $r->header('Content-Type') || '';
		warn "no Content-Type: $u\n" if $ct eq '';

		if ($atom_check && $ct =~ m!\bapplication/atom\+xml\b!) {
			my $raw = $r->decoded_content;
			my ($out, $err) = ('', '');
			my $fail = $atom_check->(\$raw, \$out, \$err);
			warn "Atom ($fail) - $u - <1:$out> <2:$err>\n" if $fail;
		}

		next if $ct !~ m!\btext/html\b!;
		my $dc = $r->decoded_content;
		if ($dc =~ /([\x00-\x08\x0d-\x1f\x7f-\x{99999999}]+)/s) {
			my $o = $1;
			my $c = Dumper($o);
			warn "bad: $u $c\n";
		}
	}
}
