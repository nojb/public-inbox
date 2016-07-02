# Copyright (C) 2015 all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)

# Streaming interface for formatting messages as an mboxrd.
# Used by the web interface
package PublicInbox::Mbox;
use strict;
use warnings;
use PublicInbox::MID qw/mid_clean/;
use URI::Escape qw/uri_escape_utf8/;
use Plack::Util;
require Email::Simple;

sub emit1 {
	my ($ctx, $msg) = @_;
	$msg = Email::Simple->new($msg);
	# single message should be easily renderable in browsers
	[200, ['Content-Type', 'text/plain'], [ msg_str($ctx, $msg)] ]
}

sub msg_str {
	my ($ctx, $simple) = @_; # Email::Simple object
	my $header_obj = $simple->header_obj;

	# drop potentially confusing headers, ssoma already should've dropped
	# Lines and Content-Length
	foreach my $d (qw(Lines Bytes Content-Length Status)) {
		$header_obj->header_set($d);
	}
	my $ibx = $ctx->{-inbox};
	my $base = $ibx->base_url($ctx->{env});
	my $mid = mid_clean($header_obj->header('Message-ID'));
	$mid = uri_escape_utf8($mid);
	my @append = (
		'Archived-At', "<$base$mid/>",
		'List-Archive', "<$base>",
		'List-Post', "<mailto:$ibx->{-primary_address}>",
	);
	my $crlf = $simple->crlf;
	my $buf = "From mboxrd\@z Thu Jan  1 00:00:00 1970\n" .
			$header_obj->as_string;
	for (my $i = 0; $i < @append; $i += 2) {
		my $k = $append[$i];
		my $v = $append[$i + 1];
		my @v = $header_obj->header($k);
		foreach (@v) {
			if ($v eq $_) {
				$v = undef;
				last;
			}
		}
		$buf .= "$k: $v$crlf" if defined $v;
	}
	$buf .= $crlf;

	# mboxrd quoting style
	# ref: http://www.qmail.org/man/man5/mbox.html
	my $body = $simple->body;
	$body =~ s/^(>*From )/>$1/gm;
	$buf .= $body;
	$buf .= "\n";
}

sub thread_mbox {
	my ($ctx, $srch, $sfx) = @_;
	eval { require IO::Compress::Gzip };
	return sub { need_gzip(@_) } if $@;

	my $cb = sub { $srch->get_thread($ctx->{mid}, @_) };
	# http://www.iana.org/assignments/media-types/application/gzip
	[200, ['Content-Type' => 'application/gzip'],
		PublicInbox::MboxGz->new($ctx, $cb) ];
}

sub emit_range {
	my ($ctx, $range) = @_;

	eval { require IO::Compress::Gzip };
	return sub { need_gzip(@_) } if $@;
	my $query;
	if ($range eq 'all') { # TODO: YYYY[-MM]
		$query = '';
	} else {
		return [404, [qw(Content-Type text/plain)], []];
	}
	my $cb = sub { $ctx->{srch}->query($query, @_) };

	# http://www.iana.org/assignments/media-types/application/gzip
	[200, [qw(Content-Type application/gzip)],
		PublicInbox::MboxGz->new($ctx, $cb) ];
}

sub need_gzip {
	my $fh = $_[0]->([501, ['Content-Type' => 'text/html']]);
	my $title = 'gzipped mbox not available';
	$fh->write(<<EOF);
<html><head><title>$title</title><body><pre>$title
The administrator needs to install the IO::Compress::Gzip Perl module
to support gzipped mboxes.
<a href="../">Return to index</a></pre></body></html>
EOF
	$fh->close;
}

1;

package PublicInbox::MboxGz;
use strict;
use warnings;

sub new {
	my ($class, $ctx, $cb) = @_;
	my $buf = '';
	bless {
		buf => \$buf,
		gz => IO::Compress::Gzip->new(\$buf, Time => 0),
		cb => $cb,
		ctx => $ctx,
		msgs => [],
		opts => { asc => 1, offset => 0 },
	}, $class;
}

# called by Plack::Util::foreach or similar
sub getline {
	my ($self) = @_;
	my $ctx = $self->{ctx} or return;
	my $res;
	my $ibx = $ctx->{-inbox};
	my $gz = $self->{gz};
	do {
		while (defined(my $smsg = shift @{$self->{msgs}})) {
			my $msg = eval { $ibx->msg_by_mid($smsg->mid) } or next;
			$msg = Email::Simple->new($msg);
			$gz->write(PublicInbox::Mbox::msg_str($ctx, $msg));
			my $bref = $self->{buf};
			if (length($$bref) >= 8192) {
				my $ret = $$bref; # copy :<
				${$self->{buf}} = '';
				return $ret;
			}
		}
		$res = $self->{cb}->($self->{opts});
		$self->{msgs} = $res->{msgs};
		$res = scalar @{$self->{msgs}};
		$self->{opts}->{offset} += $res;
	} while ($res);
	$gz->close;
	delete $self->{ctx};
	${delete $self->{buf}};
}

sub close {} # noop

1;
