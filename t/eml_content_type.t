#!perl -w
# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# Copyright (C) 2004- Simon Cozens, Casey West, Ricardo SIGNES
# This library is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.
#
# License: GPL-1.0+ or Artistic-1.0-Perl
#  <https://www.gnu.org/licenses/gpl-1.0.txt>
#  <https://dev.perl.org/licenses/artistic.html>
use strict;
use Test::More;
use PublicInbox::EmlContentFoo qw(parse_content_type);

my %ct_tests = (
	'' => {
		type       => "text",
		subtype    => "plain",
		attributes => { charset => "us-ascii" }
	},

	"text/plain" => {
		type => "text",
		subtype => "plain",
		attributes => {}
	},
	'text/plain; charset=us-ascii' => {
		type       => "text",
		subtype    => "plain",
		attributes => { charset => "us-ascii" }
	},
	'text/plain; charset="us-ascii"' => {
		type       => "text",
		subtype    => "plain",
		attributes => { charset => "us-ascii" }
	},
	"text/plain; charset=us-ascii (Plain text)" => {
		type       => "text",
		subtype    => "plain",
		attributes => { charset => "us-ascii" }
	},

	'text/plain; charset=ISO-8859-1' => {
		type       => "text",
		subtype    => "plain",
		attributes => { charset => "ISO-8859-1" }
	},
	'text/plain; charset="ISO-8859-1"' => {
		type       => "text",
		subtype    => "plain",
		attributes => { charset => "ISO-8859-1" }
	},
	'text/plain; charset="ISO-8859-1" (comment)' => {
		type       => "text",
		subtype    => "plain",
		attributes => { charset => "ISO-8859-1" }
	},

	'(c) text/plain (c); (c) charset=ISO-8859-1 (c)' => {
		type       => "text",
		subtype    => "plain",
		attributes => { charset => "ISO-8859-1" }
	},
	'(c \( \\\\) (c) text/plain (c) (c) ; (c) (c) charset=utf-8 (c)' => {
		type       => "text",
		subtype    => "plain",
		attributes => { charset => "utf-8" }
	},
	'text/plain; (c (nested ()c)another c)() charset=ISO-8859-1' => {
		type       => "text",
		subtype    => "plain",
		attributes => { charset => "ISO-8859-1" }
	},
	'text/plain (c \(!nested ()c\)\)(nested\(c())); charset=utf-8' => {
		type       => "text",
		subtype    => "plain",
		attributes => { charset => "utf-8" }
	},

	"application/foo" => {
		type       => "application",
		subtype    => "foo",
		attributes => {}
	},
	"multipart/mixed; boundary=unique-boundary-1" => {
		type       => "multipart",
		subtype    => "mixed",
		attributes => { boundary => "unique-boundary-1" }
	},
	'message/external-body; access-type=local-file; name="/u/n/m.jpg"' => {
		type       => "message",
		subtype    => "external-body",
		attributes => {
			"access-type" => "local-file",
			"name"        => "/u/n/m.jpg"
		}
	},
	'multipart/mixed; boundary="----------=_1026452699-10321-0" ' => {
		'type'       => 'multipart',
		'subtype'    => 'mixed',
		'attributes' => {
			'boundary' => '----------=_1026452699-10321-0'
		}
	},
	'multipart/report; boundary= "=_0=73e476c3-cd5a-5ba3-b910-2="' => {
		'type'       => 'multipart',
		'subtype'    => 'report',
		'attributes' => {
			'boundary' => '=_0=73e476c3-cd5a-5ba3-b910-2='
		}
	},
	'multipart/report; boundary=' . " \t" . '"=_0=7-c-5-b-2="' => {
		'type'       => 'multipart',
		'subtype'    => 'report',
		'attributes' => {
			'boundary' => '=_0=7-c-5-b-2='
		}
	},

	'message/external-body; access-type=URL;' .
	' URL*0="ftp://";' .
	' URL*1="example.com/"' => {
		'type'       => 'message',
		'subtype'    => 'external-body',
		'attributes' => {
			'access-type' => 'URL',
			'url' => 'ftp://example.com/'
		}
	},
	'message/external-body; access-type=URL; URL="ftp://example.com/"' => {
		'type'       => 'message',
		'subtype'    => 'external-body',
		'attributes' => {
			'access-type' => 'URL',
			'url' => 'ftp://example.com/',
		}
	},

	"application/x-stuff; title*=us-ascii'en-us'This%20is%20f%2Ad" => {
		'type'       => 'application',
		'subtype'    => 'x-stuff',
		'attributes' => {
			'title' => 'This is f*d'
		}
	},
	"application/x-stuff; title*=us-ascii''This%20is%20f%2Ad" => {
		'type'       => 'application',
		'subtype'    => 'x-stuff',
		'attributes' => {
			'title' => 'This is f*d'
		}
	},
	"application/x-stuff; title*=''This%20is%20f%2Ad" => {
		'type'       => 'application',
		'subtype'    => 'x-stuff',
		'attributes' => {
			'title' => 'This is f*d'
		}
	},
	"application/x-stuff; title*='en-us'This%20is%20f%2Ad" => {
		'type'       => 'application',
		'subtype'    => 'x-stuff',
		'attributes' => {
			'title' => 'This is f*d'
		}
	},
	q(application/x-stuff;) .
	q( title*0*=us-ascii'en'This%20is%20even%20more%20;) .
	q(title*1*=%2A%2A%2Afun%2A%2A%2A%20; title*2="isn't it!") => {
		'type'       => 'application',
		'subtype'    => 'x-stuff',
		'attributes' => {
			'title' => "This is even more ***fun*** isn't it!"
		}
	},
	q(application/x-stuff;) .
	q( title*0*='en'This%20is%20even%20more%20;) .
	q( title*1*=%2A%2A%2Afun%2A%2A%2A%20; title*2="isn't it!") => {
		'type'       => 'application',
		'subtype'    => 'x-stuff',
		'attributes' => {
			'title' => "This is even more ***fun*** isn't it!"
		}
	},
	q(application/x-stuff;) .
	q( title*0*=''This%20is%20even%20more%20;) .
	q( title*1*=%2A%2A%2Afun%2A%2A%2A%20; title*2="isn't it!") => {
		'type'       => 'application',
		'subtype'    => 'x-stuff',
		'attributes' => {
			'title' => "This is even more ***fun*** isn't it!"
		}
	},
	q(application/x-stuff;).
	q( title*0*=us-ascii''This%20is%20even%20more%20;).
	q( title*1*=%2A%2A%2Afun%2A%2A%2A%20; title*2="isn't it!")
	  => {
		'type'       => 'application',
		'subtype'    => 'x-stuff',
		'attributes' => {
			'title' => "This is even more ***fun*** isn't it!"
		}
	},

	'text/plain; attribute="v\"v\\\\v\(v\>\<\)\@\,\;\:\/\]\[\?\=v v";' .
	' charset=us-ascii' => {
		'type'       => 'text',
		'subtype'    => 'plain',
		'attributes' => {
			'attribute' => 'v"v\\v(v><)@,;:/][?=v v',
			'charset' => 'us-ascii',
		},
	},

	qq(text/plain;\r
	 charset=us-ascii;\r
	 attribute="\r value1 \r value2\r\n value3\r\n value4\r\n "\r\n ) => {
		'type'       => 'text',
		'subtype'    => 'plain',
		'attributes' => {
			'attribute' => ' value1  value2 value3 value4 ',
			'charset'   => 'us-ascii',
		},
	},
);

my %non_strict_ct_tests = (
	"text/plain;" => { type => "text", subtype => "plain", attributes => {} },
	"text/plain; " =>
	  { type => "text", subtype => "plain", attributes => {} },
	'image/jpeg;' .
	' x-mac-type="3F3F3F3F";'.
	' x-mac-creator="3F3F3F3F" name="file name.jpg";' => {
		type       => "image",
		subtype    => "jpeg",
		attributes => {
			'x-mac-type'    => "3F3F3F3F",
			'x-mac-creator' => "3F3F3F3F",
			'name'          => "file name.jpg"
		}
	},
	"text/plain; key=very long value" => {
		type       => "text",
		subtype    => "plain",
		attributes => { key => "very long value" }
	},
	"text/plain; key=very long value key2=value2" => {
		type    => "text",
		subtype => "plain",
		attributes => { key => "very long value", key2 => "value2" }
	},
	'multipart/mixed; boundary = "--=_Next_Part_24_Nov_2016_08.09.21"' => {
		type    => "multipart",
		subtype => "mixed",
		attributes => {
			boundary => "--=_Next_Part_24_Nov_2016_08.09.21"
		}
	},
);

sub test {
	my ($string, $expect, $info) = @_;

	# So stupid. -- rjbs, 2013-08-10
	$expect->{discrete}  = $expect->{type};
	$expect->{composite} = $expect->{subtype};

	local $_;
	$info =~ s/\r/\\r/g;
	$info =~ s/\n/\\n/g;
	is_deeply(parse_content_type($string), $expect, $info);
}

for (sort keys %ct_tests) {
	test($_, $ct_tests{$_}, "Can parse C-T <$_>");
}

local $PublicInbox::EmlContentFoo::STRICT_PARAMS = 0;
for (sort keys %ct_tests) {
	test($_, $ct_tests{$_}, "Can parse non-strict C-T <$_>");
}
for (sort keys %non_strict_ct_tests) {
	test(
		$_,
		$non_strict_ct_tests{$_},
		"Can parse non-strict C-T <$_>"
	);
}

done_testing;
