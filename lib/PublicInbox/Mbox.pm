# Copyright (C) 2015-2020 all contributors <meta@public-inbox.org>
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
use PublicInbox::MID qw/mid_escape/;
use PublicInbox::Hval qw/to_filename/;
use PublicInbox::Smsg;
use PublicInbox::Eml;

sub subject_fn ($) {
	my ($hdr) = @_;
	my $fn = $hdr->header_str('Subject');
	return 'no-subject' if (!defined($fn) || $fn eq '');

	$fn =~ s/^re:\s+//i;
	$fn eq '' ? 'no-subject' : to_filename($fn);
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
		pop @$more; # $mref
		return msg_hdr($ctx, $hdr) . msg_body($$mref);
	}
	my $cur = $next or return;
	my $ibx = $ctx->{-inbox};
	$next = $ibx->over->next_by_mid($ctx->{mid}, \$id, \$prev);
	$mref = $ibx->msg_by_smsg($cur) or return;
	$hdr = PublicInbox::Eml->new($mref)->header_obj;
	@$more = ($ctx, $id, $prev, $next); # $next may be undef, here
	msg_hdr($ctx, $hdr) . msg_body($$mref);
}

sub close {} # noop

# /$INBOX/$MESSAGE_ID/raw
sub emit_raw {
	my ($ctx) = @_;
	my $mid = $ctx->{mid};
	my $ibx = $ctx->{-inbox};
	$ctx->{base_url} = $ibx->base_url($ctx->{env});
	my ($mref, $more, $id, $prev, $next);
	if (my $over = $ibx->over) {
		my $smsg = $over->next_by_mid($mid, \$id, \$prev) or return;
		$mref = $ibx->msg_by_smsg($smsg) or return;
		$next = $over->next_by_mid($mid, \$id, \$prev);
	} else {
		$mref = $ibx->msg_by_mid($mid) or return;
	}
	my $hdr = PublicInbox::Eml->new($mref)->header_obj;
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
	# mboxrd quoting style
	# https://en.wikipedia.org/wiki/Mbox#Modified_mbox
	# https://www.loc.gov/preservation/digital/formats/fdd/fdd000385.shtml
	# https://web.archive.org/http://www.qmail.org/man/man5/mbox.html
	$_[0] =~ s/^(>*From )/>$1/gm;
	$_[0] .= "\n";
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
	require PublicInbox::MboxGz;
	my $msgs = $ctx->{msgs} = $over->get_thread($ctx->{mid}, {});
	return [404, [qw(Content-Type text/plain)], []] if !@$msgs;
	$ctx->{prev} = $msgs->[-1];
	$ctx->{over} = $over; # bump refcnt
	PublicInbox::MboxGz->response($ctx, \&thread_cb, $msgs->[0]->{subject});
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
	return PublicInbox::MboxGz->response($ctx, \&all_ids_cb, 'all');
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

	require PublicInbox::MboxGz;
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
	PublicInbox::MboxGz->response($ctx, \&results_cb, 'results-'.$query);
}

1;
