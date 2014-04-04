# Copyright (C) 2014, Eric Wong <normalperson@yhbt.net> and all contributors
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
package PublicInbox::Config;
use strict;
use warnings;
use File::Path::Expand qw/expand_filename/;

# returns key-value pairs of config directives in a hash
sub new {
	my ($class, $file) = @_;

	local $ENV{GIT_CONFIG} = defined $file ? $file : default_file();

	my @cfg = `git config -l`;
	$? == 0 or die "git config -l failed: $?\n";
	chomp @cfg;
	my %rv = map { split(/=/, $_, 2) } @cfg;
	bless \%rv, $class;
}

sub lookup {
	my ($self, $recipient) = @_;
	my $addr = lc($recipient);
	my $pfx;

	foreach my $k (keys %$self) {
		$k =~ /\A(publicinbox\.[A-Z0-9a-z-]+)\.address\z/ or next;
		(lc($self->{$k}) eq $addr) or next;
		$pfx = $1;
		last;
	}

	defined $pfx or return;

	my %rv = map {
		$_ => $self->{"$pfx.$_"}
	} (qw(mainrepo failrepo description address));
	\%rv;
}

sub get {
	my ($self, $listname, $key) = @_;

	$self->{"publicinbox.$listname.$key"};
}

sub default_file {
	my $f = $ENV{PI_CONFIG};
	return $f if defined $f;
	my $pi_dir = $ENV{PI_DIR} || expand_filename('~/.public-inbox/');
	"$pi_dir/config";
}

1;
