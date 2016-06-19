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
	my $simple = Email::Simple->new(pop);
	my $ctx = pop;
	sub {
		my ($response) = @_;
		# single message should be easily renderable in browsers
		my $fh = $response->([200, ['Content-Type'=>'text/plain']]);
		emit_msg($ctx, $fh, $simple);
		$fh->close;
	}
}

sub emit_msg {
	my ($ctx, $fh, $simple) = @_; # Email::Simple object
	my $header_obj = $simple->header_obj;

	# drop potentially confusing headers, ssoma already should've dropped
	# Lines and Content-Length
	foreach my $d (qw(Lines Bytes Content-Length Status)) {
		$header_obj->header_set($d);
	}
	my $feed_opts = $ctx->{feed_opts};
	unless ($feed_opts) {
		require PublicInbox::Feed; # FIXME: gross
		$feed_opts = PublicInbox::Feed::get_feedopts($ctx);
		$ctx->{feed_opts} = $feed_opts;
	}
	my $base = $feed_opts->{url};
	my $mid = mid_clean($header_obj->header('Message-ID'));
	$mid = uri_escape_utf8($mid);
	my @append = (
		'Archived-At', "<$base$mid/>",
		'List-Archive', "<$base>",
		'List-Post', "<mailto:$feed_opts->{id_addr}>",
	);
	my $append = '';
	my $crlf = $simple->crlf;
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
		$append .= "$k: $v$crlf" if defined $v;
	}
	my $buf = $header_obj->as_string;
	unless ($buf =~ /\AFrom /) {
		$fh->write("From mboxrd\@z Thu Jan  1 00:00:00 1970\n");
	}
	$append .= $crlf;
	$fh->write($buf .= $append);

	$buf = $simple->body;
	$simple->body_set('');

	# mboxrd quoting style
	# ref: http://www.qmail.org/man/man5/mbox.html
	$buf =~ s/^(>*From )/>$1/gm;

	$fh->write($buf .= "\n");
}

sub noop {}

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
use PublicInbox::MID qw(mid2path);

sub new {
	my ($class, $ctx, $cb) = @_;
	my $buf;
	bless {
		buf => \$buf,
		gz => IO::Compress::Gzip->new(\$buf, Time => 0),
		cb => $cb,
		ctx => $ctx,
		msgs => [],
		opts => { asc => 1, offset => 0 },
	}, $class;
}

sub _flush_buf {
	my ($self) = @_;
	my $ret = $self->{buf};
	$ret = $$ret;
	${$self->{buf}} = undef;
	$ret;
}

# called by Plack::Util::foreach or similar
sub getline {
	my ($self) = @_;
	my $res;
	my $ctx = $self->{ctx};
	my $git = $ctx->{git};
	do {
		while (defined(my $smsg = shift @{$self->{msgs}})) {
			my $msg = eval {
				my $p = 'HEAD:'.mid2path($smsg->mid);
				Email::Simple->new($git->cat_file($p));
			};
			$msg or next;

			PublicInbox::Mbox::emit_msg($ctx, $self->{gz}, $msg);
			my $ret = _flush_buf($self);
			return $ret if $ret;
		}
		$res = $self->{cb}->($self->{opts});
		$self->{msgs} = $res->{msgs};
		$res = scalar @{$self->{msgs}};
		$self->{opts}->{offset} += $res;
	} while ($res);
	$self->{gz}->close;
	_flush_buf($self);
}

sub close {} # noop

1;
