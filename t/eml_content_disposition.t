#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# Copyright (C) 2004- Simon Cozens, Casey West, Ricardo SIGNES
# This library is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.
#
# License: GPL-1.0+ or Artistic-1.0-Perl
#  <https://www.gnu.org/licenses/gpl-1.0.txt>
#  <https://dev.perl.org/licenses/artistic.html>
use strict;
use Test::More;
use PublicInbox::EmlContentFoo qw(parse_content_disposition);

my %cd_tests = (
	'' => { type => 'attachment', attributes => {} },
	'inline' => { type => 'inline', attributes => {} },
	'attachment' => { type => 'attachment', attributes => {} },

	'attachment; filename=genome.jpeg;' .
	' modification-date="Wed, 12 Feb 1997 16:29:51 -0500"' => {
		type => 'attachment',
		attributes => {
			filename => 'genome.jpeg',
			'modification-date' => 'Wed, 12 Feb 1997 16:29:51 -0500'
		}
	},

	q(attachment; filename*=UTF-8''genome.jpeg;) .
	q( modification-date="Wed, 12 Feb 1997 16:29:51 -0500") => {
		type => 'attachment',
		attributes => {
			filename => 'genome.jpeg',
			'modification-date' => 'Wed, 12 Feb 1997 16:29:51 -0500'
		}
	},

	q(attachment; filename*0*=us-ascii'en'This%20is%20even%20more%20;) .
	q( filename*1*=%2A%2A%2Afun%2A%2A%2A%20; filename*2="isn't it!") => {
		type => 'attachment',
		attributes => {
			filename => "This is even more ***fun*** isn't it!"
		}
	},

	q(attachment; filename*0*='en'This%20is%20even%20more%20;) .
	q( filename*1*=%2A%2A%2Afun%2A%2A%2A%20; filename*2="isn't it!") => {
		type => 'attachment',
		attributes => {
			filename => "This is even more ***fun*** isn't it!"
		}
	},

	q(attachment; filename*0*=''This%20is%20even%20more%20;) .
	q( filename*1*=%2A%2A%2Afun%2A%2A%2A%20; filename*2="isn't it!") => {
		type => 'attachment',
		attributes => {
			filename => "This is even more ***fun*** isn't it!"
		}
	},

	q(attachment; filename*0*=us-ascii''This%20is%20even%20more%20;).
	q( filename*1*=%2A%2A%2Afun%2A%2A%2A%20; filename*2="isn't it!") => {
		type => 'attachment',
		attributes => {
			filename => "This is even more ***fun*** isn't it!"
		}
	},
);

my %non_strict_cd_tests = (
	'attachment; filename=genome.jpeg;' .
	' modification-date="Wed, 12 Feb 1997 16:29:51 -0500";' => {
		type => 'attachment',
		attributes => {
			filename => 'genome.jpeg',
			'modification-date' =>
				'Wed, 12 Feb 1997 16:29:51 -0500'
		}
	},
);

sub test {
	my ($string, $expect, $info) = @_;
	local $_;
	$info =~ s/\r/\\r/g;
	$info =~ s/\n/\\n/g;
	is_deeply(parse_content_disposition($string), $expect, $info);
}

for (sort keys %cd_tests) {
	test($_, $cd_tests{$_}, "Can parse C-D <$_>");
}

local $PublicInbox::EmlContentFoo::STRICT_PARAMS = 0;
for (sort keys %cd_tests) {
	test($_, $cd_tests{$_}, "Can parse non-strict C-D <$_>");
}
for (sort keys %non_strict_cd_tests) {
	test($_, $non_strict_cd_tests{$_}, "Can parse non-strict C-D <$_>");
}

done_testing;
