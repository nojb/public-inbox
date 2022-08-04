# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Used for generating Atom feeds for web-accessible mailing list archives.
package PublicInbox::Feed;
use strict;
use v5.10.1;
use PublicInbox::View;
use PublicInbox::WwwAtomStream;
use PublicInbox::Smsg; # this loads w/o Search::Xapian

sub generate_i {
	my ($ctx) = @_;
	shift @{$ctx->{msgs}};
}

# main function
sub generate {
	my ($ctx) = @_;
	my $msgs = $ctx->{msgs} = recent_msgs($ctx);
	return _no_thread() unless @$msgs;
	PublicInbox::WwwAtomStream->response($ctx, 200, \&generate_i);
}

sub generate_thread_atom {
	my ($ctx) = @_;
	my $msgs = $ctx->{msgs} = $ctx->{ibx}->over->get_thread($ctx->{mid});
	return _no_thread() unless @$msgs;
	PublicInbox::WwwAtomStream->response($ctx, 200, \&generate_i);
}

sub generate_html_index {
	my ($ctx) = @_;
	# if the 'r' query parameter is given, it is a legacy permalink
	# which we must continue supporting:
	my $qp = $ctx->{qp};
	my $ibx = $ctx->{ibx};
	if ($qp && !$qp->{r} && $ibx->over) {
		return PublicInbox::View::index_topics($ctx);
	}

	my $env = $ctx->{env};
	my $url = $ibx->base_url($env) . 'new.html';
	my $qs = $env->{QUERY_STRING};
	$url .= "?$qs" if $qs ne '';
	[302, [ 'Location', $url, 'Content-Type', 'text/plain'],
		[ "Redirecting to $url\n" ] ];
}

sub new_html_i {
	my ($ctx, $eml) = @_;
	$ctx->zmore($ctx->html_top) if exists $ctx->{-html_tip};

	$eml and return PublicInbox::View::eml_entry($ctx, $eml);
	my $smsg = shift @{$ctx->{msgs}} or
		$ctx->zmore(PublicInbox::View::pagination_footer(
						$ctx, './new.html'));
	$smsg;
}

sub new_html {
	my ($ctx) = @_;
	my $msgs = $ctx->{msgs} = recent_msgs($ctx);
	if (!@$msgs) {
		return [404, ['Content-Type', 'text/plain'],
			["No messages, yet\n"] ];
	}
	$ctx->{-html_tip} = '<pre>';
	$ctx->{-upfx} = '';
	$ctx->{-hr} = 1;
	PublicInbox::WwwStream::aresponse($ctx, 200, \&new_html_i);
}

# private subs

sub _no_thread () {
	[404, ['Content-Type', 'text/plain'], ["No feed found for thread\n"]];
}

sub recent_msgs {
	my ($ctx) = @_;
	my $ibx = $ctx->{ibx};
	my $max = $ibx->{feedmax} // 25;
	return PublicInbox::View::paginate_recent($ctx, $max) if $ibx->over;

	# only for rare v1 inboxes which aren't indexed at all
	my $qp = $ctx->{qp};
	my $hex = '[a-f0-9]';
	my $addmsg = qr!^:000000 100644 \S+ (\S+) A\t${hex}{2}/${hex}{38}$!;
	my $delmsg = qr!^:100644 000000 (\S+) \S+ D\t(${hex}{2}/${hex}{38})$!;
	my $refhex = qr/(?:HEAD|${hex}{4,})(?:~[0-9]+)?/;

	# revision ranges may be specified
	my $range = 'HEAD';
	my $r = $qp->{r} if $qp;
	if ($r && ($r =~ /\A(?:$refhex\.\.)?$refhex\z/o)) {
		$range = $r;
	}

	# get recent messages
	# we could use git log -z, but, we already know ssoma will not
	# leave us with filenames with spaces in them..
	my $log = $ibx->git->popen(qw/log
				--no-notes --no-color --raw -r
				--no-abbrev --abbrev-commit/,
				"--format=%H", $range);
	my %deleted; # only an optimization at this point
	my $last;
	my $last_commit;
	local $/ = "\n";
	my @ret;
	while (defined(my $line = <$log>)) {
		if ($line =~ /$addmsg/o) {
			my $add = $1;
			next if $deleted{$add}; # optimization-only
			push(@ret, bless { blob => $add }, 'PublicInbox::Smsg');
			if (scalar(@ret) >= $max) {
				$last = 1;
				last;
			}
		} elsif ($line =~ /$delmsg/o) {
			$deleted{$1} = 1;
		}
	}

	if ($last) {
		local $/ = "\n";
		while (my $line = <$log>) {
			if ($line =~ /^(${hex}{7,})/) {
				$last_commit = $1;
				last;
			}
		}
	}

	$last_commit and
		$ctx->{next_page} = qq[<a\nhref="?r=$last_commit"\nrel=next>] .
					'next (older)</a>';
	\@ret;
}

1;
