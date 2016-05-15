# Copyright (C) 2015 all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)

# Streaming interface for formatting messages as an mboxrd.
# Used by the web interface
package PublicInbox::Mbox;
use strict;
use warnings;
use PublicInbox::MID qw/mid2path mid_clean/;
use URI::Escape qw/uri_escape_utf8/;
require Email::Simple;

sub thread_mbox {
	my ($ctx, $srch, $sfx) = @_;
	sub {
		my ($response) = @_; # Plack callback
		emit_mbox($response, $ctx, $srch, $sfx);
	}
}

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

sub emit_mbox {
	my ($response, $ctx, $srch, $sfx) = @_;
	my $type = 'mbox';
	if ($sfx) {
		eval { require IO::Compress::Gzip };
		return need_gzip($response) if $@;
		$type = 'gzip';
	}

	# http://www.iana.org/assignments/media-types/application/gzip
	# http://www.iana.org/assignments/media-types/application/mbox
	my $fh = $response->([200, ['Content-Type' => "application/$type"]]);
	$fh = PublicInbox::MboxGz->new($fh) if $sfx;

	require PublicInbox::Git;
	my $mid = $ctx->{mid};
	my $git = $ctx->{git} ||= PublicInbox::Git->new($ctx->{git_dir});
	my %opts = (offset => 0, asc => 1);
	my $nr;
	do {
		my $res = $srch->get_thread($mid, \%opts);
		my $msgs = $res->{msgs};
		$nr = scalar @$msgs;
		while (defined(my $smsg = shift @$msgs)) {
			my $msg = eval {
				my $p = 'HEAD:'.mid2path($smsg->mid);
				Email::Simple->new($git->cat_file($p));
			};
			emit_msg($ctx, $fh, $msg) if $msg;
		}

		$opts{offset} += $nr;
	} while ($nr > 0);

	$fh->close;
}

sub emit_range {
	my ($ctx, $range) = @_;
	sub { _emit_range($_[0], $ctx, $range) };
}

sub _emit_range {
	my ($res, $ctx, $range) = @_;

	eval { require IO::Compress::Gzip };
	return need_gzip($res) if $@;
	my $query;
	if ($range eq 'all') { # TODO: YYYY[-MM]
		$query = '';
	} else {
		$res->([404, [qw(Content-Type text/plain)], []]);
		return;
	}

	# http://www.iana.org/assignments/media-types/application/gzip
	my $fh = $res->([200, [qw(Content-Type application/gzip)]]);
	$fh = PublicInbox::MboxGz->new($fh);
	my $env = $ctx->{cgi}->env;
	my $srch = $ctx->{srch};
	my $git = $ctx->{git};
	my %opts = (offset => 0, asc => 1);
	my $nr;
	my $cb = sub {
		my $res = $srch->query($query, \%opts);
		my $msgs = $res->{msgs};
		$nr = scalar @$msgs;
		while (defined(my $smsg = shift @$msgs)) {
			my $msg = eval {
				my $p = 'HEAD:'.mid2path($smsg->mid);
				Email::Simple->new($git->cat_file($p));
			};
			emit_msg($ctx, $fh, $msg) if $msg;
		}

		$opts{offset} += $nr;
	};

	$cb->(); # first part is free
	return $fh->close if $nr == 0;

	if ($env->{'pi-httpd.async'}) {
		my $io = $env->{'psgix.io'} or die "no IO";
		my $next;
		$next = sub {
			$cb->();
			if ($nr > 0) {
				$io->write($next);
			} else {
				$next = undef;
				$fh->close;
			}
		};
		$io->write($next); # Danga::Socket::write
		return;
	}
	$cb->() while ($nr > 0);
	$fh->close;
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

# fh may not be a proper IO, so we wrap the write and close methods
# to prevent IO::Compress::Gzip from complaining
package PublicInbox::MboxGz;
use strict;
use warnings;

sub new {
	my ($class, $fh) = @_;
	my $buf;
	bless {
		buf => \$buf,
		gz => IO::Compress::Gzip->new(\$buf),
		fh => $fh,
	}, $class;
}

sub _flush_buf {
	my ($self) = @_;
	if (defined ${$self->{buf}}) {
		$self->{fh}->write(${$self->{buf}});
		${$self->{buf}} = undef;
	}
}

sub write {
	$_[0]->{gz}->write($_[1]);
	_flush_buf($_[0]);
}

sub close {
	my ($self) = @_;
	$self->{gz}->close;
	_flush_buf($self);
	$self->{fh}->close;
}

1;
