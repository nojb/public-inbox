# Copyright (C) 2015 all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)

sub stream_to_string {
	my ($res) = @_;
	my $body = $res->[2];
	my $str = '';
	while (defined(my $chunk = $body->getline)) {
		$str .= $chunk;
	}
	$body->close;
	$str;
}

1;
