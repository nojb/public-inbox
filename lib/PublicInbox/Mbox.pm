# Copyright (C) 2015-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Streaming (via getline) interface for formatting messages as an mboxrd.
# Used by the PSGI web interface.
#
# public-inbox-httpd favors "getline" response bodies to take a
# "pull"-based approach to feeding slow clients (as opposed to a
# more common "push" model)
package PublicInbox::Mbox;
use strict;
use warnings;
use PublicInbox::MID qw/mid_clean mid_escape/;
use PublicInbox::Hval qw/to_filename/;
use Email::Simple;
use Email::MIME::Encode;

sub subject_fn ($) {
	my ($hdr) = @_;
	my $fn = $hdr->header('Subject');
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
# this gets called twice for every message, once to return the header,
# once to retrieve the body
sub getline {
	my ($more) = @_; # self
	my ($ctx, $id, $prev, $next, $mref, $hdr) = @$more;
	if ($hdr) { # first message hits this, only
		pop @$more; # $hdr
		return msg_hdr($ctx, $hdr);
	}
	if ($mref) { # all messages hit this
		pop @$more; # $mref
		return msg_body($$mref);
	}
	my $cur = $next or return;
	my $ibx = $ctx->{-inbox};
	$next = $ibx->over->next_by_mid($ctx->{mid}, \$id, \$prev);
	$mref = $ibx->msg_by_smsg($cur) or return;
	$hdr = Email::Simple->new($mref)->header_obj;
	@$more = ($ctx, $id, $prev, $next, $mref); # $next may be undef, here
	msg_hdr($ctx, $hdr); # all but first message hits this
}

sub close {} # noop

sub emit_raw {
	my ($ctx) = @_;
	my $mid = $ctx->{mid};
	my $ibx = $ctx->{-inbox};
	my ($mref, $more, $id, $prev, $next);
	if (my $over = $ibx->over) {
		my $smsg = $over->next_by_mid($mid, \$id, \$prev) or return;
		$mref = $ibx->msg_by_smsg($smsg) or return;
		$next = $over->next_by_mid($mid, \$id, \$prev);
	} else {
		$mref = $ibx->msg_by_mid($mid) or return;
	}
	my $hdr = Email::Simple->new($mref)->header_obj;
	$more = [ $ctx, $id, $prev, $next, $mref, $hdr ]; # for ->getline
	my $fn = subject_fn($hdr);
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
	[ 200, \@hdr, mb_stream($more) ];
}

sub msg_hdr ($$;$) {
	my ($ctx, $header_obj, $mid) = @_;

	# drop potentially confusing headers, ssoma already should've dropped
	# Lines and Content-Length
	foreach my $d (qw(Lines Bytes Content-Length Status)) {
		$header_obj->header_set($d);
	}
	my $ibx = $ctx->{-inbox};
	my $base = $ibx->base_url($ctx->{env});
	$mid = $ctx->{mid} unless defined $mid;
	$mid = mid_escape($mid);
	my @append = (
		'Archived-At', "<$base$mid/>",
		'List-Archive', "<$base>",
		'List-Post', "<mailto:$ibx->{-primary_address}>",
	);
	my $crlf = $header_obj->crlf;
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
}

sub msg_body ($) {
	# mboxrd quoting style
	# https://en.wikipedia.org/wiki/Mbox#Modified_mbox
	# https://www.loc.gov/preservation/digital/formats/fdd/fdd000385.shtml
	# https://web.archive.org/http://www.qmail.org/man/man5/mbox.html
	$_[0] =~ s/^(>*From )/>$1/gm;
	$_[0] .= "\n";
}

sub thread_mbox {
	my ($ctx, $over, $sfx) = @_;
	eval { require IO::Compress::Gzip };
	return sub { need_gzip(@_) } if $@;
	my $mid = $ctx->{mid};
	my $msgs = $over->get_thread($mid, {});
	return [404, [qw(Content-Type text/plain)], []] if !@$msgs;
	my $prev = $msgs->[-1];
	my $i = 0;
	my $cb = sub {
		while (1) {
			if (my $smsg = $msgs->[$i++]) {
				return $smsg;
			}
			# refill result set
			$msgs = $over->get_thread($mid, $prev);
			return unless @$msgs;
			$prev = $msgs->[-1];
			$i = 0;
		}
	};
	PublicInbox::MboxGz->response($ctx, $cb, $msgs->[0]->subject);
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

sub mbox_all_ids {
	my ($ctx) = @_;
	my $prev = 0;
	my $ibx = $ctx->{-inbox};
	my $ids = $ibx->mm->ids_after(\$prev) or return
		[404, [qw(Content-Type text/plain)], ["No results found\n"]];
	my $i = 0;
	my $over = $ibx->over or
		return PublicInbox::WWW::need($ctx, 'Overview');
	my $cb = sub {
		do {
			while ((my $num = $ids->[$i++])) {
				my $smsg = $over->get_art($num) or next;
				return $smsg;
			}
			$ids = $ibx->mm->ids_after(\$prev);
			$i = 0;
		} while (@$ids);
		undef;
	};
	return PublicInbox::MboxGz->response($ctx, $cb, 'all');
}

sub mbox_all {
	my ($ctx, $query) = @_;

	eval { require IO::Compress::Gzip };
	return sub { need_gzip(@_) } if $@;
	return mbox_all_ids($ctx) if $query eq '';
	my $opts = { mset => 2 };
	my $srch = $ctx->{-inbox}->search or
		return PublicInbox::WWW::need($ctx, 'Search');;
	my $mset = $srch->query($query, $opts);
	$opts->{offset} = $mset->size or
			return [404, [qw(Content-Type text/plain)],
				["No results found\n"]];
	my $i = 0;
	my $cb = sub { # called by MboxGz->getline
		while (1) {
			while (my $mi = (($mset->items)[$i++])) {
				my $doc = $mi->get_document;
				my $smsg = $srch->retry_reopen(sub {
					PublicInbox::SearchMsg->load_doc($doc);
				}) or next;
				return $smsg;
			}
			# refill result set
			$mset = $srch->query($query, $opts);
			my $size = $mset->size or return;
			$opts->{offset} += $size;
			$i = 0;
		}
	};
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
	}, $class;
}

sub response {
	my ($class, $ctx, $cb, $fn) = @_;
	my $body = $class->new($ctx, $cb);
	# http://www.iana.org/assignments/media-types/application/gzip
	my @h = qw(Content-Type application/gzip);
	if ($fn) {
		$fn = to_filename($fn);
		push @h, 'Content-Disposition', "inline; filename=$fn.mbox.gz";
	}
	[ 200, \@h, $body ];
}

# called by Plack::Util::foreach or similar
sub getline {
	my ($self) = @_;
	my $ctx = $self->{ctx} or return;
	my $gz = $self->{gz};
	while (my $smsg = $self->{cb}->()) {
		my $mref = $ctx->{-inbox}->msg_by_smsg($smsg) or next;
		my $h = Email::Simple->new($mref)->header_obj;
		$gz->write(PublicInbox::Mbox::msg_hdr($ctx, $h, $smsg->{mid}));
		$gz->write(PublicInbox::Mbox::msg_body($$mref));

		my $bref = $self->{buf};
		if (length($$bref) >= 8192) {
			my $ret = $$bref; # copy :<
			${$self->{buf}} = '';
			return $ret;
		}

		# be fair to other clients on public-inbox-httpd:
		return '';
	}
	delete($self->{gz})->close;
	# signal that we're done and can return undef next call:
	delete $self->{ctx};
	${delete $self->{buf}};
}

sub close {} # noop

1;
