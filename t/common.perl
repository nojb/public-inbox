# Copyright (C) 2015 all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
require IO::File;
use POSIX qw/dup/;

sub stream_to_string {
	my ($cb) = @_;
	my $headers;
	my $io = IO::File->new_tmpfile;
	my $dup = dup($io->fileno);
	my $response = sub { $headers = \@_, $io };
	$cb->($response);
	$io = IO::File->new;
	$io->fdopen($dup, 'r+');
	$io->seek(0, 0);
	$io->read(my $str, ($io->stat)[7]);
	$str;
}
