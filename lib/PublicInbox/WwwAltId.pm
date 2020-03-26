# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# dumps using the ".dump" command of sqlite3(1)
package PublicInbox::WwwAltId;
use strict;
use PublicInbox::Qspawn;
use PublicInbox::WwwStream;
use PublicInbox::AltId;
use PublicInbox::Spawn qw(which);
our $sqlite3 = $ENV{SQLITE3};

sub sqlite3_missing ($) {
	PublicInbox::WwwResponse::oneshot($_[0], 501, \<<EOF);
<pre>sqlite3 not available

The administrator needs to install the sqlite3(1) binary
to support gzipped sqlite3 dumps.</pre>
</pre>
EOF
}

sub check_output {
	my ($r, $bref, $ctx) = @_;
	return PublicInbox::WwwResponse::oneshot($ctx, 500) if !defined($r);
	if ($r == 0) {
		my $err = eval { $ctx->{env}->{'psgi.errors'} } // \*STDERR;
		$err->print("unexpected EOF from sqlite3\n");
		return PublicInbox::WwwResponse::oneshot($ctx, 501);
	}
	[200, [ qw(Content-Type application/gzip), 'Content-Disposition',
		"inline; filename=$ctx->{altid_pfx}.sql.gz" ] ]
}

# POST $INBOX/$prefix.sql.gz
# we use the sqlite3(1) binary here since that's where the ".dump"
# command is implemented, not (AFAIK) in the libsqlite3 library
# and thus not usable from DBD::SQLite.
sub sqldump ($$) {
	my ($ctx, $altid_pfx) = @_;
	my $ibx = $ctx->{-inbox};
	my $altid_map = $ibx->altid_map;
	my $fn = $altid_map->{$altid_pfx};
	unless (defined $fn) {
		return PublicInbox::WwwStream::oneshot($ctx, 404, \<<EOF);
<pre>`$altid_pfx' is not a valid altid for this inbox</pre>
EOF
	}

	eval { require PublicInbox::GzipFilter } or
		return PublicInbox::WwwStream::oneshot($ctx, 501, \<<EOF);
<pre>gzip output not available

The administrator needs to install the Compress::Raw::Zlib Perl module
to support gzipped sqlite3 dumps.</pre>
EOF
	$sqlite3 //= which('sqlite3');
	if (!defined($sqlite3)) {
		return PublicInbox::WwwStream::oneshot($ctx, 501, \<<EOF);
<pre>sqlite3 not available

The administrator needs to install the sqlite3(1) binary
to support gzipped sqlite3 dumps.</pre>
</pre>
EOF
	}

	# setup stdin, POSIX requires writes <= 512 bytes to succeed so
	# we can close the pipe right away.
	pipe(my ($r, $w)) or die "pipe: $!";
	syswrite($w, ".dump\n") == 6 or die "write: $!";
	close($w) or die "close: $!";

	# TODO: use -readonly if available with newer sqlite3(1)
	my $qsp = PublicInbox::Qspawn->new([$sqlite3, $fn], undef, { 0 => $r });
	my $env = $ctx->{env};
	$ctx->{altid_pfx} = $altid_pfx;
	$env->{'qspawn.filter'} = PublicInbox::GzipFilter->new;
	$qsp->psgi_return($env, undef, \&check_output, $ctx);
}

1;
