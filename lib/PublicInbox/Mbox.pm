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
	my $mid = mid_compressed($ctx->{mid});
	my $res = $srch->get_thread($mid);
	my $msgs = delete $res->{msgs};
	require PublicInbox::GitCatFile;
	require Email::Simple;
	my $git = PublicInbox::GitCatFile->new($ctx->{git_dir});

	sub {
		my ($res) = @_; # Plack callback
		my $w = $res->([200, [ 'Content-Type' => 'text/plain' ] ]);
		while (defined(my $smsg = shift @$msgs)) {
			my $msg = eval {
				my $path = 'HEAD:' . mid2path($smsg->mid);
				Email::Simple->new($git->cat_file($path));
			};
			emit($w, $msg) if $msg;
		}
	}
}

sub emit {
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

1;
