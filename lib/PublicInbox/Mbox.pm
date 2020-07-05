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
use PublicInbox::GitAsyncCat;
use PublicInbox::GzipFilter qw(gzf_maybe);

# called by PSGI server as body response
# this gets called twice for every message, once to return the header,
# once to retrieve the body
sub getline {
	my ($ctx) = @_; # ctx
	my $smsg = $ctx->{smsg} or return;
	my $ibx = $ctx->{-inbox};
	my $eml = $ibx->smsg_eml($smsg) or return;
	$ctx->{smsg} = $ibx->over->next_by_mid($ctx->{mid}, @{$ctx->{id_prev}});
	msg_hdr($ctx, $eml, $smsg->{mid}) . msg_body($eml);
}

sub close { !!delete($_[0]->{http_out}) }

sub mbox_async_step ($) { # public-inbox-httpd-only
	my ($ctx) = @_;
	if (my $smsg = $ctx->{smsg}) {
		git_async_cat($ctx->{-inbox}->git, $smsg->{blob},
				\&mbox_blob_cb, $ctx);
	} elsif (my $out = delete $ctx->{http_out}) {
		$out->close;
	}
}

# called by PublicInbox::DS::write
sub mbox_async_next {
	my ($http) = @_; # PublicInbox::HTTP
	my $ctx = $http->{forward} or return; # client aborted
	eval {
		$ctx->{smsg} = $ctx->{-inbox}->over->next_by_mid(
					$ctx->{mid}, @{$ctx->{id_prev}});
		mbox_async_step($ctx);
	};
}

# this is public-inbox-httpd-specific
sub mbox_blob_cb { # git->cat_async callback
	my ($bref, $oid, $type, $size, $ctx) = @_;
	my $http = $ctx->{env}->{'psgix.io'} or return; # client abort
	my $smsg = delete $ctx->{smsg} or die 'BUG: no smsg';
	if (!defined($oid)) {
		# it's possible to have TOCTOU if an admin runs
		# public-inbox-(edit|purge), just move onto the next message
		return $http->next_step(\&mbox_async_next);
	} else {
		$smsg->{blob} eq $oid or die "BUG: $smsg->{blob} != $oid";
	}
	my $eml = PublicInbox::Eml->new($bref);
	$ctx->{http_out}->write(msg_hdr($ctx, $eml, $smsg->{mid}));
	$ctx->{http_out}->write(msg_body($eml));
	$http->next_step(\&mbox_async_next);
}

sub res_hdr ($$) {
	my ($ctx, $subject) = @_;
	my $fn = $subject // 'no-subject';
	$fn =~ s/^re:\s+//i;
	$fn = $fn eq '' ? 'no-subject' : to_filename($fn);
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

sub stream_raw { # MboxGz response callback
	my ($ctx) = @_;
	delete($ctx->{smsg}) //
		$ctx->{-inbox}->over->next_by_mid($ctx->{mid},
						@{$ctx->{id_prev}});
}

# /$INBOX/$MESSAGE_ID/raw
sub emit_raw {
	my ($ctx) = @_;
	my $env = $ctx->{env};
	$ctx->{base_url} = $ctx->{-inbox}->base_url($env);
	my $over = $ctx->{-inbox}->over or return no_over_raw($ctx);
	my ($id, $prev);
	my $smsg = $over->next_by_mid($ctx->{mid}, \$id, \$prev) or return;
	$ctx->{smsg} = $smsg;
	my $res_hdr = res_hdr($ctx, $smsg->{subject});
	$ctx->{id_prev} = [ \$id, \$prev ];

	if (my $gzf = gzf_maybe($res_hdr, $env)) {
		$ctx->{gz} = delete $gzf->{gz};
		require PublicInbox::MboxGz;
		PublicInbox::MboxGz::response($ctx, \&stream_raw, $res_hdr);
	} elsif ($env->{'pi-httpd.async'}) {
		sub {
			my ($wcb) = @_; # -httpd provided write callback
			$ctx->{http_out} = $wcb->([200, $res_hdr]);
			$ctx->{env}->{'psgix.io'}->{forward} = $ctx;
			bless $ctx, __PACKAGE__;
			mbox_async_step($ctx); # start stepping
		};
	} else { # generic PSGI code path
		bless $ctx, __PACKAGE__; # respond to ->getline
		[ 200, $res_hdr, $ctx ];
	}
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
