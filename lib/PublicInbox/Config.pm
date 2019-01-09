# Copyright (C) 2014-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Used throughout the project for reading configuration
package PublicInbox::Config;
use strict;
use warnings;
require PublicInbox::Inbox;
use PublicInbox::Spawn qw(popen_rd);

# returns key-value pairs of config directives in a hash
# if keys may be multi-value, the value is an array ref containing all values
sub new {
	my ($class, $file) = @_;
	$file = default_file() unless defined($file);
	$file = ref $file ? $file : git_config_dump($file);
	my $self = bless $file, $class;

	# caches
	$self->{-by_addr} ||= {};
	$self->{-by_name} ||= {};
	$self->{-by_newsgroup} ||= {};
	$self->{-no_obfuscate} ||= {};
	$self->{-limiters} ||= {};

	if (my $no = delete $self->{'publicinbox.noobfuscate'}) {
		$no = [ $no ] if ref($no) ne 'ARRAY';
		my @domains;
		foreach my $n (@$no) {
			my @n = split(/\s+/, $n);
			foreach (@n) {
				if (/\S+@\S+/) { # full address
					$self->{-no_obfuscate}->{lc $_} = 1;
				} else {
					# allow "example.com" or "@example.com"
					s/\A@//;
					push @domains, quotemeta($_);
				}
			}
		}
		my $nod = join('|', @domains);
		$self->{-no_obfuscate_re} = qr/(?:$nod)\z/i;
	}

	$self;
}

sub lookup {
	my ($self, $recipient) = @_;
	my $addr = lc($recipient);
	my $inbox = $self->{-by_addr}->{$addr};
	return $inbox if $inbox;

	my $pfx;

	foreach my $k (keys %$self) {
		$k =~ m!\A(publicinbox\.[^/]+)\.address\z! or next;
		my $v = $self->{$k};
		if (ref($v) eq "ARRAY") {
			foreach my $alias (@$v) {
				(lc($alias) eq $addr) or next;
				$pfx = $1;
				last;
			}
		} else {
			(lc($v) eq $addr) or next;
			$pfx = $1;
			last;
		}
	}
	defined $pfx or return;
	_fill($self, $pfx);
}

sub lookup_name ($$) {
	my ($self, $name) = @_;
	$self->{-by_name}->{$name} || _fill($self, "publicinbox.$name");
}

sub each_inbox {
	my ($self, $cb) = @_;
	my %seen;
	foreach my $k (keys %$self) {
		$k =~ m!\Apublicinbox\.([^/]+)\.mainrepo\z! or next;
		next if $seen{$1};
		$seen{$1} = 1;
		my $ibx = lookup_name($self, $1) or next;
		$cb->($ibx);
	}
}

sub lookup_newsgroup {
	my ($self, $ng) = @_;
	$ng = lc($ng);
	my $rv = $self->{-by_newsgroup}->{$ng};
	return $rv if $rv;

	foreach my $k (keys %$self) {
		$k =~ m!\A(publicinbox\.[^/]+)\.newsgroup\z! or next;
		my $v = $self->{$k};
		my $pfx = $1;
		if ($v eq $ng) {
			$rv = _fill($self, $pfx);
			return $rv;
		}
	}
	undef;
}

sub limiter {
	my ($self, $name) = @_;
	$self->{-limiters}->{$name} ||= do {
		require PublicInbox::Qspawn;
		my $max = $self->{"publicinboxlimiter.$name.max"};
		PublicInbox::Qspawn::Limiter->new($max);
	};
}

sub config_dir { $ENV{PI_DIR} || "$ENV{HOME}/.public-inbox" }

sub default_file {
	my $f = $ENV{PI_CONFIG};
	return $f if defined $f;
	config_dir() . '/config';
}

sub git_config_dump {
	my ($file) = @_;
	my ($in, $out);
	my @cmd = (qw/git config/, "--file=$file", '-l');
	my $cmd = join(' ', @cmd);
	my $fh = popen_rd(\@cmd) or die "popen_rd failed for $file: $!\n";
	my %rv;
	local $/ = "\n";
	while (defined(my $line = <$fh>)) {
		chomp $line;
		my ($k, $v) = split(/=/, $line, 2);
		my $cur = $rv{$k};

		if (defined $cur) {
			if (ref($cur) eq "ARRAY") {
				push @$cur, $v;
			} else {
				$rv{$k} = [ $cur, $v ];
			}
		} else {
			$rv{$k} = $v;
		}
	}
	close $fh or die "failed to close ($cmd) pipe: $?";

	\%rv;
}

sub valid_inbox_name ($) {
	my ($name) = @_;

	# Similar rules found in git.git/remote.c::valid_remote_nick
	# and git.git/refs.c::check_refname_component
	# We don't reject /\.lock\z/, however, since we don't lock refs
	if ($name eq '' || $name =~ /\@\{/ ||
	    $name =~ /\.\./ || $name =~ m![/:\?\[\]\^~\s\f[:cntrl:]\*]! ||
	    $name =~ /\A\./ || $name =~ /\.\z/) {
		return 0;
	}

	# Note: we allow URL-unfriendly characters; users may configure
	# non-HTTP-accessible inboxes
	1;
}

sub _fill {
	my ($self, $pfx) = @_;
	my $rv = {};

	foreach my $k (qw(mainrepo filter url newsgroup
			infourl watch watchheader httpbackendmax
			replyto feedmax nntpserver indexlevel)) {
		my $v = $self->{"$pfx.$k"};
		$rv->{$k} = $v if defined $v;
	}
	foreach my $k (qw(obfuscate)) {
		my $v = $self->{"$pfx.$k"};
		defined $v or next;
		if ($v =~ /\A(?:false|no|off|0)\z/) {
			$rv->{$k} = 0;
		} elsif ($v =~ /\A(?:true|yes|on|1)\z/) {
			$rv->{$k} = 1;
		} else {
			warn "Ignoring $pfx.$k=$v in config, not boolean\n";
		}
	}
	# TODO: more arrays, we should support multi-value for
	# more things to encourage decentralization
	foreach my $k (qw(address altid nntpmirror)) {
		if (defined(my $v = $self->{"$pfx.$k"})) {
			$rv->{$k} = ref($v) eq 'ARRAY' ? $v : [ $v ];
		}
	}

	return unless $rv->{mainrepo};
	my $name = $pfx;
	$name =~ s/\Apublicinbox\.//;

	if (!valid_inbox_name($name)) {
		warn "invalid inbox name: '$name'\n";
		return;
	}

	$rv->{name} = $name;
	$rv->{-pi_config} = $self;
	$rv = PublicInbox::Inbox->new($rv);
	foreach (@{$rv->{address}}) {
		my $lc_addr = lc($_);
		$self->{-by_addr}->{$lc_addr} = $rv;
		$self->{-no_obfuscate}->{$lc_addr} = 1;
	}
	if (my $ng = $rv->{newsgroup}) {
		$self->{-by_newsgroup}->{$ng} = $rv;
	}
	$self->{-by_name}->{$name} = $rv;
	if ($rv->{obfuscate}) {
		$rv->{-no_obfuscate} = $self->{-no_obfuscate};
		$rv->{-no_obfuscate_re} = $self->{-no_obfuscate_re};
		each_inbox($self, sub {}); # noop to populate -no_obfuscate
	}
	$rv
}

1;
