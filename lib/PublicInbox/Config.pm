# Copyright (C) 2014-2015 all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
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
	$self;
}

sub lookup {
	my ($self, $recipient) = @_;
	my $addr = lc($recipient);
	my $inbox = $self->{-by_addr}->{$addr};
	return $inbox if $inbox;

	my $pfx;

	foreach my $k (keys %$self) {
		$k =~ /\A(publicinbox\.[\w-]+)\.address\z/ or next;
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

sub lookup_name {
	my ($self, $name) = @_;
	my $rv = $self->{-by_name}->{$name};
	return $rv if $rv;
	$rv = _fill($self, "publicinbox.$name") or return;
}

sub lookup_newsgroup {
	my ($self, $ng) = @_;
	$ng = lc($ng);
	my $rv = $self->{-by_newsgroup}->{$ng};
	return $rv if $rv;

	foreach my $k (keys %$self) {
		$k =~ /\A(publicinbox\.[\w-]+)\.newsgroup\z/ or next;
		my $v = $self->{$k};
		my $pfx = $1;
		if ($v eq $ng) {
			$rv = _fill($self, $pfx);
			return $rv;
		}
	}
	undef;
}

sub get {
	my ($self, $inbox, $key) = @_;

	$self->{"publicinbox.$inbox.$key"};
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
	my $fh = popen_rd(\@cmd);
	my %rv;
	local $/ = "\n";
	foreach my $line (<$fh>) {
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

sub _fill {
	my ($self, $pfx) = @_;
	my $rv = {};

	foreach my $k (qw(mainrepo address filter url newsgroup
			watch watchheader)) {
		my $v = $self->{"$pfx.$k"};
		$rv->{$k} = $v if defined $v;
	}
	return unless $rv->{mainrepo};
	my $name = $pfx;
	$name =~ s/\Apublicinbox\.//;
	$rv->{name} = $name;
	$rv = PublicInbox::Inbox->new($rv);
	my $v = $rv->{address};
	if (ref($v) eq 'ARRAY') {
		$self->{-by_addr}->{lc($_)} = $rv foreach @$v;
	} else {
		$self->{-by_addr}->{lc($v)} = $rv;
	}
	if (my $ng = $rv->{newsgroup}) {
		$self->{-by_newsgroup}->{$ng} = $rv;
	}
	$self->{-by_name}->{$name} = $rv;
}

1;
