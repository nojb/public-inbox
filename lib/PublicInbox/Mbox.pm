# Copyright (C) 2015, all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
# Streaming interface for formatting messages as an mbox
package PublicInbox::Mbox;
use strict;
use warnings;
use PublicInbox::MID qw/mid_clean mid_compressed mid2path/;
use Fcntl qw(SEEK_SET);

sub thread_mbox {
	my ($ctx, $srch) = @_;
	sub {
		my ($response) = @_; # Plack callback
		my $w = $response->([200, ['Content-Type' => 'text/plain']]);
		emit_mbox($w, $ctx, $srch);
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
	my ($fh, $ctx, $srch) = @_;

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
}

1;
