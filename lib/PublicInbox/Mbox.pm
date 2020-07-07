# Copyright (C) 2015-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Streaming interface for mboxrd HTTP responses
# See PublicInbox::GzipFilter for details.
package PublicInbox::Mbox;
use strict;
use parent 'PublicInbox::GzipFilter';
use PublicInbox::MID qw/mid_escape/;
use PublicInbox::Hval qw/to_filename/;
use PublicInbox::Smsg;
use PublicInbox::Eml;

# called by PSGI server as body response
# this gets called twice for every message, once to return the header,
# once to retrieve the body
sub getline {
	my ($ctx) = @_; # ctx
	my $smsg = $ctx->{smsg} or return;
	my $ibx = $ctx->{-inbox};
	my $eml = $ibx->smsg_eml($smsg) or return;
	my $n = $ctx->{smsg} = $ibx->over->next_by_mid(@{$ctx->{next_arg}});
	$ctx->zmore(msg_hdr($ctx, $eml, $smsg->{mid}));
	if ($n) {
		$ctx->translate(msg_body($eml));
	} else { # last message
		$ctx->zmore(msg_body($eml));
		$ctx->zflush;
	}
}

# called by PublicInbox::DS::write
sub async_next {
	my ($http) = @_; # PublicInbox::HTTP
	my $ctx = $http->{forward} or return; # client aborted
	eval {
		my $smsg = $ctx->{smsg} or return $ctx->close;
		$ctx->smsg_blob($smsg);
	};
	warn "E: $@" if $@;
}

sub async_eml { # ->{async_eml} for async_blob_cb
	my ($ctx, $eml) = @_;
	my $smsg = delete $ctx->{smsg};
	# next message
	$ctx->{smsg} = $ctx->{-inbox}->over->next_by_mid(@{$ctx->{next_arg}});

	$ctx->zmore(msg_hdr($ctx, $eml, $smsg->{mid}));
	$ctx->{http_out}->write($ctx->translate(msg_body($eml)));
}

sub res_hdr ($$) {
	my ($ctx, $subject) = @_;
	my $fn = $subject // '';
	$fn =~ s/^re:\s+//i;
	$fn = to_filename($fn) // 'no-subject';
	my @hdr = ('Content-Type');
	if ($ctx->{-inbox}->{obfuscate}) {
		# obfuscation is stupid, but maybe scrapers are, too...
		push @hdr, 'application/mbox';
		$fn .= '.mbox';
	} else {
		push @hdr, 'text/plain';
		$fn .= '.txt';
	}
	push @hdr, 'Content-Disposition', "inline; filename=$fn";
	\@hdr;
}

# for rare cases where v1 inboxes aren't indexed w/ ->over at all
sub no_over_raw ($) {
	my ($ctx) = @_;
	my $mref = $ctx->{-inbox}->msg_by_mid($ctx->{mid}) or return;
	my $eml = PublicInbox::Eml->new($mref);
	[ 200, res_hdr($ctx, $eml->header_str('Subject')),
		[ msg_hdr($ctx, $eml, $ctx->{mid}) . msg_body($eml) ] ]
}

# /$INBOX/$MESSAGE_ID/raw
sub emit_raw {
	my ($ctx) = @_;
	$ctx->{base_url} = $ctx->{-inbox}->base_url($ctx->{env});
	my $over = $ctx->{-inbox}->over or return no_over_raw($ctx);
	my ($id, $prev);
	my $mip = $ctx->{next_arg} = [ $ctx->{mid}, \$id, \$prev ];
	my $smsg = $ctx->{smsg} = $over->next_by_mid(@$mip) or return;
	my $res_hdr = res_hdr($ctx, $smsg->{subject});
	bless $ctx, __PACKAGE__;
	$ctx->psgi_response(200, $res_hdr, \&async_next, \&async_eml);
}

sub msg_hdr ($$;$) {
	my ($ctx, $eml, $mid) = @_;
	my $header_obj = $eml->header_obj;

	# drop potentially confusing headers, ssoma already should've dropped
	# Lines and Content-Length
	foreach my $d (qw(Lines Bytes Content-Length Status)) {
		$header_obj->header_set($d);
	}
	my $ibx = $ctx->{-inbox};
	my $base = $ctx->{base_url};
	$mid = $ctx->{mid} unless defined $mid;
	$mid = mid_escape($mid);
	my @append = (
		'Archived-At', "<$base$mid/>",
		'List-Archive', "<$base>",
		'List-Post', "<mailto:$ibx->{-primary_address}>",
	);
	my $crlf = $header_obj->crlf;
	my $buf = $header_obj->as_string;
	# fixup old bug from import (pre-a0c07cba0e5d8b6a)
	$buf =~ s/\A[\r\n]*From [^\r\n]*\r?\n//s;
	$buf = "From mboxrd\@z Thu Jan  1 00:00:00 1970" . $crlf . $buf;

	for (my $i = 0; $i < @append; $i += 2) {
		my $k = $append[$i];
		my $v = $append[$i + 1];
		my @v = $header_obj->header_raw($k);
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
	my $bdy = $_[0]->{bdy} // return "\n";
	# mboxrd quoting style
	# https://en.wikipedia.org/wiki/Mbox#Modified_mbox
	# https://www.loc.gov/preservation/digital/formats/fdd/fdd000385.shtml
	# https://web.archive.org/http://www.qmail.org/man/man5/mbox.html
	$$bdy =~ s/^(>*From )/>$1/gm;
	$$bdy .= "\n";
}

sub thread_cb {
	my ($ctx) = @_;
	my $msgs = $ctx->{msgs};
	while (1) {
		if (my $smsg = shift @$msgs) {
			return $smsg;
		}
		# refill result set
		$ctx->{msgs} = $msgs = $ctx->{over}->get_thread($ctx->{mid},
								$ctx->{prev});
		return unless @$msgs;
		$ctx->{prev} = $msgs->[-1];
	}
}

sub thread_mbox {
	my ($ctx, $over, $sfx) = @_;
	my $msgs = $ctx->{msgs} = $over->get_thread($ctx->{mid}, {});
	return [404, [qw(Content-Type text/plain)], []] if !@$msgs;
	$ctx->{prev} = $msgs->[-1];
	$ctx->{over} = $over; # bump refcnt
	require PublicInbox::MboxGz;
	PublicInbox::MboxGz::mbox_gz($ctx, \&thread_cb, $msgs->[0]->{subject});
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

sub all_ids_cb {
	my ($ctx) = @_;
	my $ids = $ctx->{ids};
	do {
		while ((my $num = shift @$ids)) {
			my $smsg = $ctx->{over}->get_art($num) or next;
			return $smsg;
		}
		$ctx->{ids} = $ids = $ctx->{mm}->ids_after(\($ctx->{prev}));
	} while (@$ids);
}

sub mbox_all_ids {
	my ($ctx) = @_;
	my $ibx = $ctx->{-inbox};
	my $prev = 0;
	my $mm = $ctx->{mm} = $ibx->mm;
	my $ids = $mm->ids_after(\$prev) or return
		[404, [qw(Content-Type text/plain)], ["No results found\n"]];
	$ctx->{over} = $ibx->over or
		return PublicInbox::WWW::need($ctx, 'Overview');
	$ctx->{ids} = $ids;
	$ctx->{prev} = $prev;
	require PublicInbox::MboxGz;
	PublicInbox::MboxGz::mbox_gz($ctx, \&all_ids_cb, 'all');
}

sub results_cb {
	my ($ctx) = @_;
	my $mset = $ctx->{mset};
	my $srch = $ctx->{srch};
	while (1) {
		while (my $mi = (($mset->items)[$ctx->{iter}++])) {
			my $smsg = PublicInbox::Smsg::from_mitem($mi,
								$srch) or next;
			return $smsg;
		}
		# refill result set
		$mset = $ctx->{mset} = $srch->query($ctx->{query},
							$ctx->{qopts});
		my $size = $mset->size or return;
		$ctx->{qopts}->{offset} += $size;
		$ctx->{iter} = 0;
	}
}

sub mbox_all {
	my ($ctx, $query) = @_;

	return mbox_all_ids($ctx) if $query eq '';
	my $qopts = $ctx->{qopts} = { mset => 2 };
	my $srch = $ctx->{srch} = $ctx->{-inbox}->search or
		return PublicInbox::WWW::need($ctx, 'Search');;
	my $mset = $ctx->{mset} = $srch->query($query, $qopts);
	$qopts->{offset} = $mset->size or
			return [404, [qw(Content-Type text/plain)],
				["No results found\n"]];
	$ctx->{iter} = 0;
	$ctx->{query} = $query;
	require PublicInbox::MboxGz;
	PublicInbox::MboxGz::mbox_gz($ctx, \&results_cb, 'results-'.$query);
}

1;
