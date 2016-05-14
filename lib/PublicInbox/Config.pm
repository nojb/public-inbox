# Copyright (C) 2014-2015 all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
#
# Used throughout the project for reading configuration
package PublicInbox::Config;
use strict;
use warnings;
use base qw/Exporter/;
our @EXPORT_OK = qw/try_cat/;
require PublicInbox::Inbox;
use File::Path::Expand qw/expand_filename/;

# returns key-value pairs of config directives in a hash
# if keys may be multi-value, the value is an array ref containing all values
sub new {
	my ($class, $file) = @_;
	$file = default_file() unless defined($file);
	my $self = bless git_config_dump($file), $class;
	$self->{-by_addr} = {};
	$self->{-by_name} = {};
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
	$self->{-by_name}->{$name} = _fill($self, "publicinbox.$name");
}

sub get {
	my ($self, $inbox, $key) = @_;

	$self->{"publicinbox.$inbox.$key"};
}

sub config_dir { $ENV{PI_DIR} || expand_filename('~/.public-inbox') }

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
	my $pid = open(my $fh, '-|', @cmd);
	defined $pid or die "$cmd failed: $!";
	my %rv;
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
	close $fh or die "failed to close ($cmd) pipe: $!";
	$? and warn "$$ $cmd exited with: ($pid) $?";
	\%rv;
}

sub try_cat {
	my ($path) = @_;
	my $rv;
	if (open(my $fh, '<', $path)) {
		local $/;
		$rv = <$fh>;
	}
	$rv;
}

sub _fill {
	my ($self, $pfx) = @_;
	my $rv = {};

	foreach my $k (qw(mainrepo address filter url)) {
		my $v = $self->{"$pfx.$k"};
		$rv->{$k} = $v if defined $v;
	}
	my $inbox = $pfx;
	$inbox =~ s/\Apublicinbox\.//;
	$rv->{name} = $inbox;
	my $v = $rv->{address} ||= 'public-inbox@example.com';
	$rv->{-primary_address} = ref($v) eq 'ARRAY' ? $v->[0] : $v;
	$rv = PublicInbox::Inbox->new($rv);
	if (ref($v) eq 'ARRAY') {
		$self->{-by_addr}->{lc($_)} = $rv foreach @$v;
	} else {
		$self->{-by_addr}->{lc($v)} = $rv;
	}
	$rv;
}


1;
