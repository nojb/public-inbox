# Copyright (C) 2015-2021 all contributors <meta@public-inbox.org>
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
	my $ibx = $ctx->{ibx};
	my $eml = delete($ctx->{eml}) // $ibx->smsg_eml($smsg) // return;
	my $n = $ctx->{smsg} = $ibx->over->next_by_mid(@{$ctx->{next_arg}});
	$ctx->zmore(msg_hdr($ctx, $eml));
	if ($n) {
		$ctx->translate(msg_body($eml));
	} else { # last message
		$ctx->zmore(msg_body($eml));
		$ctx->zflush;
	}
}

# called by PublicInbox::DS::write after http->next_step
sub async_next {
	my ($http) = @_; # PublicInbox::HTTP
	my $ctx = $http->{forward} or return; # client aborted
	eval {
		my $smsg = $ctx->{smsg} or return $ctx->close;
		$ctx->smsg_blob($smsg);
	};
	warn "E: $@" if $@;
}

sub async_eml { # for async_blob_cb
	my ($ctx, $eml) = @_;
	my $smsg = delete $ctx->{smsg};
	# next message
	$ctx->{smsg} = $ctx->{ibx}->over->next_by_mid(@{$ctx->{next_arg}});
	local $ctx->{eml} = $eml; # for mbox_hdr
	$ctx->zmore(msg_hdr($ctx, $eml));
	$ctx->write(msg_body($eml));
}

sub mbox_hdr ($) {
	my ($ctx) = @_;
	my $eml = $ctx->{eml} //= $ctx->{ibx}->smsg_eml($ctx->{smsg});
	my $fn = $eml->header_str('Subject') // '';
	$fn =~ s/^re:\s+//i;
	$fn = to_filename($fn) // 'no-subject';
	my @hdr = ('Content-Type');
	if ($ctx->{ibx}->{obfuscate}) {
		# obfuscation is stupid, but maybe scrapers are, too...
		push @hdr, 'application/mbox';
		$fn .= '.mbox';
	} else {
		push @hdr, 'text/plain';
		$fn .= '.txt';
	}
	my $cs = $ctx->{eml}->ct->{attributes}->{charset} // 'UTF-8';
	$cs = 'UTF-8' if $cs =~ /[^a-zA-Z0-9\-\_]/; # avoid header injection
	$hdr[-1] .= "; charset=$cs";
	push @hdr, 'Content-Disposition', "inline; filename=$fn";
	[ 200, \@hdr ];
}

# for rare cases where v1 inboxes aren't indexed w/ ->over at all
sub no_over_raw ($) {
	my ($ctx) = @_;
	my $mref = $ctx->{ibx}->msg_by_mid($ctx->{mid}) or return;
	my $eml = $ctx->{eml} = PublicInbox::Eml->new($mref);
	[ @{mbox_hdr($ctx)}, [ msg_hdr($ctx, $eml) . msg_body($eml) ] ]
}

# /$INBOX/$MESSAGE_ID/raw
sub emit_raw {
	my ($ctx) = @_;
	$ctx->{base_url} = $ctx->{ibx}->base_url($ctx->{env});
	my $over = $ctx->{ibx}->over or return no_over_raw($ctx);
	my ($id, $prev);
	my $mip = $ctx->{next_arg} = [ $ctx->{mid}, \$id, \$prev ];
	my $smsg = $ctx->{smsg} = $over->next_by_mid(@$mip) or return;
	bless $ctx, __PACKAGE__;
	$ctx->psgi_response(\&mbox_hdr);
}

sub msg_hdr ($$) {
	my ($ctx, $eml) = @_;
	my $header_obj = $eml->header_obj;

	# drop potentially confusing headers, ssoma already should've dropped
	# Lines and Content-Length
	foreach my $d (qw(Lines Bytes Content-Length Status)) {
		$header_obj->header_set($d);
	}
	my $crlf = $header_obj->crlf;
	my $buf = $header_obj->as_string;
	# fixup old bug from import (pre-a0c07cba0e5d8b6a)
	$buf =~ s/\A[\r\n]*From [^\r\n]*\r?\n//s;
	"From mboxrd\@z Thu Jan  1 00:00:00 1970" . $crlf . $buf . $crlf;
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
		my $over = $ctx->{ibx}->over or return $ctx->gone('over');
		$ctx->{msgs} = $msgs = $over->get_thread($ctx->{mid},
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
	require PublicInbox::MboxGz;
	PublicInbox::MboxGz::mbox_gz($ctx, \&thread_cb, $msgs->[0]->{subject});
}

sub emit_range {
	my ($ctx, $range) = @_;

	my $q;
	if ($range eq 'all') { # TODO: YYYY[-MM]
		$q = '';
	} else {
		return [404, [qw(Content-Type text/plain)], []];
	}
	mbox_all($ctx, { q => $q });
}

sub all_ids_cb {
	my ($ctx) = @_;
	my $over = $ctx->{ibx}->over or return $ctx->gone('over');
	my $ids = $ctx->{ids};
	do {
		while ((my $num = shift @$ids)) {
			my $smsg = $over->get_art($num) or next;
			return $smsg;
		}
		$ctx->{ids} = $ids = $over->ids_after(\($ctx->{prev}));
	} while (@$ids);
}

sub mbox_all_ids {
	my ($ctx) = @_;
	my $prev = 0;
	my $over = $ctx->{ibx}->over or
		return PublicInbox::WWW::need($ctx, 'Overview');
	my $ids = $over->ids_after(\$prev) or return
		[404, [qw(Content-Type text/plain)], ["No results found\n"]];
	$ctx->{ids} = $ids;
	$ctx->{prev} = $prev;
	$ctx->{-low_prio} = 1;
	require PublicInbox::MboxGz;
	PublicInbox::MboxGz::mbox_gz($ctx, \&all_ids_cb, 'all');
}

sub results_cb {
	my ($ctx) = @_;
	my $over = $ctx->{ibx}->over or return $ctx->gone('over');
	while (1) {
		while (defined(my $num = shift(@{$ctx->{ids}}))) {
			my $smsg = $over->get_art($num) or next;
			return $smsg;
		}
		# refill result set, deprioritize since there's many results
		my $srch = $ctx->{ibx}->isrch or return $ctx->gone('search');
		my $mset = $srch->mset($ctx->{query}, $ctx->{qopts});
		my $size = $mset->size or return;
		$ctx->{qopts}->{offset} += $size;
		$ctx->{ids} = $srch->mset_to_artnums($mset, $ctx->{qopts});
		$ctx->{-low_prio} = 1;
	}
}

sub results_thread_cb {
	my ($ctx) = @_;

	my $over = $ctx->{ibx}->over or return $ctx->gone('over');
	while (1) {
		while (defined(my $num = shift(@{$ctx->{xids}}))) {
			my $smsg = $over->get_art($num) or next;
			return $smsg;
		}

		# refills ctx->{xids}
		next if $over->expand_thread($ctx);

		# refill result set, deprioritize since there's many results
		my $srch = $ctx->{ibx}->isrch or return $ctx->gone('search');
		my $mset = $srch->mset($ctx->{query}, $ctx->{qopts});
		my $size = $mset->size or return;
		$ctx->{qopts}->{offset} += $size;
		$ctx->{ids} = $srch->mset_to_artnums($mset, $ctx->{qopts});
		$ctx->{-low_prio} = 1;
	}

}

sub mbox_all {
	my ($ctx, $q) = @_;
	my $q_string = $q->{'q'};
	return mbox_all_ids($ctx) if $q_string !~ /\S/;
	my $srch = $ctx->{ibx}->isrch or
		return PublicInbox::WWW::need($ctx, 'Search');
	my $over = $ctx->{ibx}->over or
		return PublicInbox::WWW::need($ctx, 'Overview');

	my $qopts = $ctx->{qopts} = { relevance => -2 }; # ORDER BY docid DESC
	$qopts->{threads} = 1 if $q->{t};
	$srch->query_approxidate($ctx->{ibx}->git, $q_string);
	my $mset = $srch->mset($q_string, $qopts);
	$qopts->{offset} = $mset->size or
			return [404, [qw(Content-Type text/plain)],
				["No results found\n"]];
	$ctx->{query} = $q_string;
	$ctx->{ids} = $srch->mset_to_artnums($mset, $qopts);
	require PublicInbox::MboxGz;
	my $fn;
	if ($q->{t} && $srch->has_threadid) {
		$fn = 'results-thread-'.$q_string;
		PublicInbox::MboxGz::mbox_gz($ctx, \&results_thread_cb, $fn);
	} else {
		$fn = 'results-'.$q_string;
		PublicInbox::MboxGz::mbox_gz($ctx, \&results_cb, $fn);
	}
}

1;
