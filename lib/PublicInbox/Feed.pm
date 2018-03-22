# Copyright (C) 2013-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Used for generating Atom feeds for web-accessible mailing list archives.
package PublicInbox::Feed;
use strict;
use warnings;
use PublicInbox::MIME;
use PublicInbox::View;
use PublicInbox::WwwAtomStream;

# main function
sub generate {
	my ($ctx) = @_;
	my @oids;
	each_recent_blob($ctx, sub { push @oids, $_[0] });
	return _no_thread() unless @oids;

	my $git = $ctx->{-inbox}->git;
	PublicInbox::WwwAtomStream->response($ctx, 200, sub {
		while (my $oid = shift @oids) {
			my $msg = $git->cat_file($oid) or next;
			return PublicInbox::MIME->new($msg);
		}
	});
}

sub generate_thread_atom {
	my ($ctx) = @_;
	my $mid = $ctx->{mid};
	my $res = $ctx->{srch}->get_thread($mid);
	return _no_thread() unless $res->{total};

	my $ibx = $ctx->{-inbox};
	my $html_url = $ibx->base_url($ctx->{env});
	$html_url .= PublicInbox::Hval->new_msgid($mid)->{href};
	$ctx->{-html_url} = $html_url;
	my $msgs = $res->{msgs};
	PublicInbox::WwwAtomStream->response($ctx, 200, sub {
		while (my $msg = shift @$msgs) {
			$msg = $ibx->msg_by_smsg($msg) and
				return PublicInbox::MIME->new($msg);
		}
	});
}

sub generate_html_index {
	my ($ctx) = @_;
	# if the 'r' query parameter is given, it is a legacy permalink
	# which we must continue supporting:
	my $qp = $ctx->{qp};
	if ($qp && !$qp->{r} && $ctx->{srch}) {
		return PublicInbox::View::index_topics($ctx);
	}

	my $env = $ctx->{env};
	my $url = $ctx->{-inbox}->base_url($env) . 'new.html';
	my $qs = $env->{QUERY_STRING};
	$url .= "?$qs" if $qs ne '';
	[302, [ 'Location', $url, 'Content-Type', 'text/plain'],
		[ "Redirecting to $url\n" ] ];
}

sub new_html {
	my ($ctx) = @_;
	die "BUG: new_html is not used with search" if $ctx->{srch};
	my @oids;
	my (undef, $last) = each_recent_blob($ctx, sub {
		my ($oid, $commit, $ts, $u, $subj) = @_;
		$ctx->{first} ||= $commit;
		push @oids, $oid;
	});
	if (!@oids) {
		return [404, ['Content-Type', 'text/plain'],
			["No messages, yet\n"] ];
	}
	$ctx->{-html_tip} = '<pre>';
	$ctx->{-upfx} = '';
	$ctx->{-hr} = 1;
	my $git = $ctx->{-inbox}->git;
	PublicInbox::WwwStream->response($ctx, 200, sub {
		while (my $oid = shift @oids) {
			my $msg = $git->cat_file($oid) or next;
			my $m = PublicInbox::MIME->new($msg);
			my $more = scalar @oids;
			return PublicInbox::View::index_entry($m, $ctx, $more);
		}
		new_html_footer($ctx, $last);
	});
}

# private subs

sub _no_thread () {
	[404, ['Content-Type', 'text/plain'], ["No feed found for thread\n"]];
}

sub new_html_footer {
	my ($ctx, $last) = @_;
	my $qp = delete $ctx->{qp} or return;
	my $old_r = $qp->{r};
	my $latest = '';
	my $next = '    ';

	if ($last) {
		$next = qq!<a\nhref="?r=$last"\nrel=next>next</a>!;
	}
	if ($old_r) {
		$latest = qq! <a\nhref='./new.html'>latest</a>!;
	}
	"<hr><pre>page: $next$latest</pre>";
}

sub each_recent_blob {
	my ($ctx, $cb) = @_;
	my $ibx = $ctx->{-inbox};
	my $max = $ibx->{feedmax};
	my $v = $ibx->{version} || 1;
	if ($v == 2) {
		wantarray and die "each_recent_blob return ignored for v2";
	} elsif ($v != 1) {
		die "BUG: unsupported inbox version: $v\n";
	}
	if (my $srch = $ibx->search) {
		my $res = $srch->query('', { limit => $max });
		foreach my $smsg (@{$res->{msgs}}) {
			# search-enabled callers do not need author/date/subject
			$cb->($smsg->{blob});
		}
		return;
	}

	my $hex = '[a-f0-9]';
	my $addmsg = qr!^:000000 100644 \S+ (\S+) A\t${hex}{2}/${hex}{38}$!;
	my $delmsg = qr!^:100644 000000 (\S+) \S+ D\t(${hex}{2}/${hex}{38})$!;
	my $refhex = qr/(?:HEAD|${hex}{4,40})(?:~\d+)?/;
	my $qp = $ctx->{qp};

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
				"--format=%h%x00%ct%x00%an%x00%s%x00",
				$range);
	my %deleted; # only an optimization at this point
	my $last;
	my $nr = 0;
	my ($cur_commit, $first_commit, $last_commit);
	my ($ts, $subj, $u);
	local $/ = "\n";
	while (defined(my $line = <$log>)) {
		if ($line =~ /$addmsg/o) {
			my $add = $1;
			next if $deleted{$add}; # optimization-only
			$cb->($add, $cur_commit, $ts, $u, $subj) and $nr++;
			if ($nr >= $max) {
				$last = 1;
				last;
			}
		} elsif ($line =~ /$delmsg/o) {
			$deleted{$1} = 1;
		} elsif ($line =~ /^${hex}{7,40}/o) {
			($cur_commit, $ts, $u, $subj) = split("\0", $line);
			unless (defined $first_commit) {
				$first_commit = $cur_commit;
			}
		}
	}

	if ($last) {
		local $/ = "\n";
		while (my $line = <$log>) {
			if ($line =~ /^(${hex}{7,40})/o) {
				$last_commit = $1;
				last;
			}
		}
	}

	# for pagination
	($first_commit, $last_commit);
}

1;
