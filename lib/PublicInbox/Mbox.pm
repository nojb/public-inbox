# Copyright (C) 2015-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Streaming interface for formatting messages as an mboxrd.
# Used by the web interface
package PublicInbox::Mbox;
use strict;
use warnings;
use PublicInbox::MID qw/mid_clean mid_escape/;
use PublicInbox::Hval qw/to_filename/;
use Email::Simple;
use Email::MIME::Encode;

sub subject_fn ($) {
	my ($simple) = @_;
	my $fn = $simple->header('Subject');
	return 'no-subject' unless defined($fn);

	# no need for full Email::MIME, here
	if ($fn =~ /=\?/) {
		eval { $fn = Encode::decode('MIME-Header', $fn) };
		$fn = 'no-subject' if $@;
	}
	$fn =~ s/^re:\s+//i;
	$fn = to_filename($fn);
	$fn eq '' ? 'no-subject' : $fn;
}

sub mb_stream {
	my ($more) = @_;
	bless $more, 'PublicInbox::Mbox';
}

# called by PSGI server as body response
sub getline {
	my ($more) = @_; # self
	my ($ctx, $head, $tail, $db, $cur) = @$more;
	if ($cur) {
		pop @$more;
		return msg_str($ctx, $cur);
	}
	for (; !defined($cur) && $head != $tail; $head++) {
		my $smsg = PublicInbox::SearchMsg->get($head, $db, $ctx->{mid});
		my $mref = $ctx->{-inbox}->msg_by_smsg($smsg) or next;
		$cur = Email::Simple->new($mref);
		$cur = msg_str($ctx, $cur);
	}
	$more->[1] = $head;
	$cur;
}

sub close {} # noop

sub emit_raw {
	my ($ctx) = @_;
	my $mid = $ctx->{mid};
	my $ibx = $ctx->{-inbox};
	my $first;
	my $more;
	my ($head, $tail, $db);
	my %seen;
	if (my $srch = $ibx->search) {
		$srch->retry_reopen(sub {
			($head, $tail, $db) = $srch->each_smsg_by_mid($mid);
			for (; !defined($first) && $head != $tail; $head++) {
				my @args = ($head, $db, $mid);
				my $smsg = PublicInbox::SearchMsg->get(@args);
				my $mref = $ibx->msg_by_smsg($smsg) or next;
				$first = Email::Simple->new($mref);
			}
			if ($head != $tail) {
				$more = [ $ctx, $head, $tail, $db, $first ];
			}
		});
	} else {
		my $mref = $ibx->msg_by_mid($mid) or return;
		$first = Email::Simple->new($mref);
	}
	return unless defined $first;
	my $fn = subject_fn($first);
	my @hdr = ('Content-Type');
	if ($ibx->{obfuscate}) {
		# obfuscation is stupid, but maybe scrapers are, too...
		push @hdr, 'application/mbox';
		$fn .= '.mbox';
	} else {
		push @hdr, 'text/plain';
		$fn .= '.txt';
	}
	push @hdr, 'Content-Disposition', "inline; filename=$fn";
	[ 200, \@hdr, $more ? mb_stream($more) : [ msg_str($ctx, $first) ] ];
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
	$mid = mid_escape($mid);
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
	PublicInbox::MboxGz->response($ctx, $cb);
}

sub emit_range {
	my ($ctx, $range) = @_;

	my $query;
	if ($range eq 'all') { # TODO: YYYY[-MM]
		$query = '';
	} else {
		return [404, [qw(Content-Type text/plain)], []];
	}
	mbox_all($ctx, $query);
}

sub mbox_all {
	my ($ctx, $query) = @_;

	eval { require IO::Compress::Gzip };
	return sub { need_gzip(@_) } if $@;
	my $cb = sub { $ctx->{srch}->query($query, @_) };
	PublicInbox::MboxGz->response($ctx, $cb, 'results-'.$query);
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
use PublicInbox::Hval qw/to_filename/;

sub new {
	my ($class, $ctx, $cb) = @_;
	my $buf = '';
	bless {
		buf => \$buf,
		gz => IO::Compress::Gzip->new(\$buf, Time => 0),
		cb => $cb,
		ctx => $ctx,
		msgs => [],
		opts => { offset => 0 },
	}, $class;
}

sub response {
	my ($class, $ctx, $cb, $fn) = @_;
	my $body = $class->new($ctx, $cb);
	# http://www.iana.org/assignments/media-types/application/gzip
	$body->{hdr} = [ 'Content-Type', 'application/gzip' ];
	$body->{fn} = $fn;
	my $hdr = $body->getline; # fill in Content-Disposition filename
	[ 200, $hdr, $body ];
}

sub set_filename ($$) {
	my ($fn, $msg) = @_;
	return to_filename($fn) if defined($fn);

	PublicInbox::Mbox::subject_fn($msg);
}

# called by Plack::Util::foreach or similar
sub getline {
	my ($self) = @_;
	my $ctx = $self->{ctx} or return;
	my $res;
	my $ibx = $ctx->{-inbox};
	my $gz = $self->{gz};
	do {
		# work on existing result set
		while (defined(my $smsg = shift @{$self->{msgs}})) {
			my $msg = eval { $ibx->msg_by_smsg($smsg) } or next;
			$msg = Email::Simple->new($msg);
			$gz->write(PublicInbox::Mbox::msg_str($ctx, $msg));

			# use subject of first message as subject
			if (my $hdr = delete $self->{hdr}) {
				my $fn = set_filename($self->{fn}, $msg);
				push @$hdr, 'Content-Disposition',
						"inline; filename=$fn.mbox.gz";
				return $hdr;
			}
			my $bref = $self->{buf};
			if (length($$bref) >= 8192) {
				my $ret = $$bref; # copy :<
				${$self->{buf}} = '';
				return $ret;
			}

			# be fair to other clients on public-inbox-httpd:
			return '';
		}

		# refill result set
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
