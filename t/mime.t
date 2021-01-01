#!perl -w
# Copyright (C) 2017-2021 all contributors <meta@public-inbox.org>
# This library is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.
# Artistic or GPL-1+ <https://www.gnu.org/licenses/gpl-1.0.txt>
use strict;
use Test::More;
use PublicInbox::TestCommon;
use PublicInbox::MsgIter;
my @classes = qw(PublicInbox::Eml);
SKIP: {
	require_mods('Email::MIME', 1);
	push @classes, 'PublicInbox::MIME';
};
use_ok $_ for @classes;
local $SIG{__WARN__} = sub {}; # needed for old Email::Simple (used by E::M)

for my $cls (@classes) {
	my $msg = $cls->new(<<'EOF');
From:   Richard Hansen <hansenr@google.com>
To:     git@vger.kernel.org
Cc:     Richard Hansen <hansenr@google.com>
Subject: [PATCH 0/2] minor diff orderfile documentation improvements
Date:   Mon,  9 Jan 2017 19:40:29 -0500
Message-Id: <20170110004031.57985-1-hansenr@google.com>
X-Mailer: git-send-email 2.11.0.390.gc69c2f50cf-goog
Content-Type: multipart/signed; protocol="application/pkcs7-signature"; micalg=sha-256;
        boundary="94eb2c0bc864b76ba30545b2bca9"

--94eb2c0bc864b76ba30545b2bca9

Richard Hansen (2):
  diff: document behavior of relative diff.orderFile
  diff: document the pattern format for diff.orderFile

 Documentation/diff-config.txt  | 5 ++++-
 Documentation/diff-options.txt | 3 ++-
 2 files changed, 6 insertions(+), 2 deletions(-)


--94eb2c0bc864b76ba30545b2bca9
Content-Type: application/pkcs7-signature; name="smime.p7s"
Content-Transfer-Encoding: base64
Content-Disposition: attachment; filename="smime.p7s"
Content-Description: (truncated) S/MIME Cryptographic Signature

dkTlB69771K2eXK4LcHSH/2LqX+VYa3K44vrx1ruzjXdNWzIpKBy0weFNiwnJCGofvCysM2RCSI1
--94eb2c0bc864b76ba30545b2bca9--

EOF

	my @parts = $msg->subparts;
	my $exp = <<EOF;
Richard Hansen (2):
  diff: document behavior of relative diff.orderFile
  diff: document the pattern format for diff.orderFile

 Documentation/diff-config.txt  | 5 ++++-
 Documentation/diff-options.txt | 3 ++-
 2 files changed, 6 insertions(+), 2 deletions(-)

EOF

	is($parts[0]->body, $exp, 'body matches expected');

	my $raw = <<'EOF';
Date:   Wed, 18 Jan 2017 13:28:32 -0500
From:   Santiago Torres <santiago@nyu.edu>
To:     Junio C Hamano <gitster@pobox.com>
Cc:     git@vger.kernel.org, peff@peff.net, sunshine@sunshineco.com,
        walters@verbum.org, Lukas Puehringer <luk.puehringer@gmail.com>
Subject: Re: [PATCH v6 4/6] builtin/tag: add --format argument for tag -v
Message-ID: <20170118182831.pkhqu2np3bh2puei@LykOS.localdomain>
References: <20170117233723.23897-1-santiago@nyu.edu>
 <20170117233723.23897-5-santiago@nyu.edu>
 <xmqqmvepb4oj.fsf@gitster.mtv.corp.google.com>
 <xmqqh94wb4y0.fsf@gitster.mtv.corp.google.com>
MIME-Version: 1.0
Content-Type: multipart/signed; micalg=pgp-sha256;
        protocol="application/pgp-signature"; boundary="r24xguofrazenjwe"
Content-Disposition: inline
In-Reply-To: <xmqqh94wb4y0.fsf@gitster.mtv.corp.google.com>


--r24xguofrazenjwe
Content-Type: text/plain; charset=us-ascii
Content-Disposition: inline
Content-Transfer-Encoding: quoted-printable

your tree directly?=20

--r24xguofrazenjwe
Content-Type: application/pgp-signature; name="signature.asc"

-----BEGIN PGP SIGNATURE-----

=7wIb
-----END PGP SIGNATURE-----

--r24xguofrazenjwe--

EOF

	$msg = $cls->new($raw);
	my $nr = 0;
	msg_iter($msg, sub {
		my ($part, $level, @ex) = @{$_[0]};
		is($level, 1, 'at expected level');
		if (join('fail if $#ex > 0', @ex) eq '1') {
			is($part->body_str, "your tree directly? \r\n",
			'body OK');
		} elsif (join('fail if $#ex > 0', @ex) eq '2') {
			is($part->body, "-----BEGIN PGP SIGNATURE-----\n\n" .
					"=7wIb\n" .
					"-----END PGP SIGNATURE-----\n",
				'sig "matches"');
		} else {
			fail "unexpected part\n";
		}
		$nr++;
	});

	is($nr, 2, 'got 2 parts');
	is($msg->as_string, $raw,
		'stringified sufficiently close to original');
}

done_testing();
