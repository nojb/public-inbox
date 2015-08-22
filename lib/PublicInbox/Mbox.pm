# Copyright (C) 2015, all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
# Streaming interface for formatting messages as an mbox
package PublicInbox::Mbox;
use strict;
use warnings;
use PublicInbox::MID qw/mid_compressed mid2path/;

sub thread_mbox {
	my ($ctx, $srch) = @_;
	sub {
		my ($response) = @_; # Plack callback
		emit_mbox($response, $ctx, $srch);
	}
}

sub emit_msg {
	my ($fh, $simple) = @_; # Email::Simple object

	# drop potentially confusing headers, ssoma already should've dropped
	# Lines and Content-Length
	foreach my $d (qw(Lines Content-Length Status)) {
		$simple->header_set($d);
	}

	my $buf = $simple->header_obj->as_string;
	unless ($buf =~ /\AFrom /) {
		$fh->write("From a\@a Thu Jan  1 00:00:00 1970\n");
	}
	$fh->write($buf .= $simple->crlf);

	$buf = $simple->body;
	$simple->body_set('');
	$buf =~ s/^(From )/>$1/gm;
	$buf .= "\n" unless $buf =~ /\n\z/s;

	$fh->write($buf);
}

sub emit_mbox {
	my ($response, $ctx, $srch) = @_;
	eval { require IO::Compress::Gzip };
	return need_gzip($response) if $@;

	# http://www.iana.org/assignments/media-types/application/gzip
	# http://www.iana.org/assignments/media-types/application/mbox
	my $fh = $response->([200, ['Content-Type' => 'application/gzip']]);
	$fh = PublicInbox::MboxGz->new($fh);

	require PublicInbox::GitCatFile;
	require Email::Simple;
	my $mid = mid_compressed($ctx->{mid});
	my $git = PublicInbox::GitCatFile->new($ctx->{git_dir});
	my %opts = (offset => 0);
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
			emit_msg($fh, $msg) if $msg;
		}

		$opts{offset} += $nr;
	} while ($nr > 0);

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
use fields qw(gz fh buf);

sub new {
	my ($class, $fh) = @_;
	my $self = fields::new($class);
	my $buf;
	$self->{buf} = \$buf;
	$self->{gz} = IO::Compress::Gzip->new(\$buf);
	$self->{fh} = $fh;
	$self;
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
