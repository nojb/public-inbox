# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Provide the same methods as Compress::Raw::Zlib::Deflate but
# does no transformation of outgoing data
package PublicInbox::CompressNoop;
use strict;
use Compress::Raw::Zlib qw(Z_OK);

sub new { bless \(my $self), __PACKAGE__ }

sub deflate { # ($self, $input, $output)
	$_[2] .= ref($_[1]) ? ${$_[1]} : $_[1];
	Z_OK;
}

sub flush { # ($self, $output, $flags = Z_FINISH)
	$_[1] //= '';
	Z_OK;
}

1;
