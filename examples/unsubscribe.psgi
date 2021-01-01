#!/usr/bin/perl -w
# Copyright (C) 2016-2021 all contributors <meta@public-inbox.org>
# License: GPL-3.0+ <https://www.gnu.org/licenses/gpl-3.0.txt>
# This should not require any other PublicInbox code, but may use
# PublicInbox::Config if ~/.public-inbox/config exists or
# PI_CONFIG is pointed to an appropriate location
use strict;
use Plack::Builder;
use PublicInbox::Unsubscribe;
my $app = PublicInbox::Unsubscribe->new(
	pi_config => eval { # optional, for pointing out archives
		require PublicInbox::Config;
		# uses ~/.public-inbox/config by default,
		# can override with PI_CONFIG or here since
		# I run this .psgi as the mlmmj user while the
		# public-inbox-mda code which actually writes to
		# the archives runs as a different user.
		PublicInbox::Config->new('/home/pi/.public-inbox/config')
	},
	# change if you fork
	code_url => 'https://public-inbox.org/public-inbox.git',
	owner_email => 'BOFH@example.com',
	confirm => 0,

	# First 8 bytes is for the key, next 8 bytes is for the IV
	# using Blowfish.  We want as short URLs as possible to avoid
	# copy+paste errors
	# umask 077 && dd if=/dev/urandom bs=16 count=1 of=.unsubscribe.key
	key_file => '/home/mlmmj/.unsubscribe.key',

	# this runs as whatever user has perms to run /usr/bin/mlmmj-unsub
	# users of other mailing lists.  Returns '' on success.
	unsubscribe => sub {
		my ($user_addr, $list_addr) = @_;

		# map list_addr to mlmmj spool, I use:
		# /home/mlmmj/spool/$LIST here
		my ($list, $domain) = split('@', $list_addr, 2);
		my $spool = "/home/mlmmj/spool/$list";

		return "Invalid list: $list" unless -d $spool;

		# -c to send a confirmation email, -s is important
		# in case a user is click-happy and clicks twice.
		my @cmd = (qw(/usr/bin/mlmmj-unsub -c -s),
				'-L', $spool, '-a', $user_addr);

		# we don't know which version they're subscribed to,
		# try both non-digest and digest
		my $normal = system(@cmd);
		my $digest = system(@cmd, '-d');

		# success if either succeeds:
		return '' if ($normal == 0 || $digest == 0);

		# missing executable or FS error,
		# otherwise -s always succeeds, right?
		return 'Unknown error, contact admin';
	},
);

builder {
	mount '/u' => builder {
		eval { enable 'ReverseProxy' }; # optional
		enable 'Head';
		sub { $app->call(@_) };
	};
};
