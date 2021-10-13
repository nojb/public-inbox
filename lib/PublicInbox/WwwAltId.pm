# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# dumps using the ".dump" command of sqlite3(1)
package PublicInbox::WwwAltId;
use strict;
use PublicInbox::Qspawn;
use PublicInbox::WwwStream qw(html_oneshot);
use PublicInbox::AltId;
use PublicInbox::Spawn qw(which);
use PublicInbox::GzipFilter;
our $sqlite3 = $ENV{SQLITE3};

sub check_output {
	my ($r, $bref, $ctx) = @_;
	return html_oneshot($ctx, 500) if !defined($r);
	if ($r == 0) {
		warn 'unexpected EOF from sqlite3';
		return html_oneshot($ctx, 501);
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
	my $env = $ctx->{env};
	my $ibx = $ctx->{ibx};
	my $altid_map = $ibx->altid_map;
	my $fn = $altid_map->{$altid_pfx};
	unless (defined $fn) {
		return html_oneshot($ctx, 404, \<<EOF);
<pre>`$altid_pfx' is not a valid altid for this inbox</pre>
EOF
	}

	if ($env->{REQUEST_METHOD} ne 'POST') {
		my $url = $ibx->base_url($ctx->{env}) . "$altid_pfx.sql.gz";
		return html_oneshot($ctx, 405, \<<EOF);
<pre>A POST request is required to retrieve $altid_pfx.sql.gz

	curl -d '' -O $url

or

	curl -d '' $url | \\
		gzip -dc | \\
		sqlite3 /path/to/$altid_pfx.sqlite3
</pre>
EOF
	}

	$sqlite3 //= which('sqlite3') // return html_oneshot($ctx, 501, \<<EOF);
<pre>sqlite3 not available

The administrator needs to install the sqlite3(1) binary
to support gzipped sqlite3 dumps.</pre>
EOF

	# setup stdin, POSIX requires writes <= 512 bytes to succeed so
	# we can close the pipe right away.
	pipe(my ($r, $w)) or die "pipe: $!";
	syswrite($w, ".dump\n") == 6 or die "write: $!";
	close($w) or die "close: $!";

	# TODO: use -readonly if available with newer sqlite3(1)
	my $qsp = PublicInbox::Qspawn->new([$sqlite3, $fn], undef, { 0 => $r });
	$ctx->{altid_pfx} = $altid_pfx;
	$env->{'qspawn.filter'} = PublicInbox::GzipFilter->new;
	$qsp->psgi_return($env, undef, \&check_output, $ctx);
}

1;
