# Copyright (C) 2019-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# show any VCS object, similar to "git show"
# FIXME: we only show blobs for now
#
# This can use a "solver" to reconstruct blobs based on git
# patches (with abbreviated OIDs in the header).  However, the
# abbreviated OIDs must match exactly what's in the original
# email (unless a normal code repo already has the blob).
#
# In other words, we can only reliably reconstruct blobs based
# on links generated by ViewDiff (and only if the emailed
# patches apply 100% cleanly to published blobs).

package PublicInbox::ViewVCS;
use strict;
use warnings;
use bytes (); # only for bytes::length
use PublicInbox::SolverGit;
use PublicInbox::WwwStream qw(html_oneshot);
use PublicInbox::Linkify;
use PublicInbox::Tmpfile;
use PublicInbox::Hval qw(ascii_html to_filename);
my $hl = eval {
	require PublicInbox::HlMod;
	PublicInbox::HlMod->new;
};

my %QP_MAP = ( A => 'oid_a', a => 'path_a', b => 'path_b' );
our $MAX_SIZE = 1024 * 1024; # TODO: configurable
my $BIN_DETECT = 8000; # same as git

sub html_page ($$$) {
	my ($ctx, $code, $strref) = @_;
	my $wcb = delete $ctx->{-wcb};
	$ctx->{-upfx} = '../../'; # from "/$INBOX/$OID/s/"
	my $res = html_oneshot($ctx, $code, $strref);
	$wcb ? $wcb->($res) : $res;
}

sub stream_blob_parse_hdr { # {parse_hdr} for Qspawn
	my ($r, $bref, $ctx) = @_;
	my ($res, $logref) = delete @$ctx{qw(-res -logref)};
	my ($git, $oid, $type, $size, $di) = @$res;
	my @cl = ('Content-Length', $size);
	if (!defined $r) { # error
		html_page($ctx, 500, $logref);
	} elsif (index($$bref, "\0") >= 0) {
		[200, [qw(Content-Type application/octet-stream), @cl] ];
	} else {
		my $n = bytes::length($$bref);
		if ($n >= $BIN_DETECT || $n == $size) {
			return [200, [ 'Content-Type',
				'text/plain; charset=UTF-8', @cl ] ];
		}
		if ($r == 0) {
			warn "premature EOF on $oid $$logref\n";
			return html_page($ctx, 500, $logref);
		}
		@$ctx{qw(-res -logref)} = ($res, $logref);
		undef; # bref keeps growing
	}
}

sub stream_large_blob ($$$$) {
	my ($ctx, $res, $logref, $fn) = @_;
	$ctx->{-logref} = $logref;
	$ctx->{-res} = $res;
	my ($git, $oid, $type, $size, $di) = @$res;
	my $cmd = ['git', "--git-dir=$git->{git_dir}", 'cat-file', $type, $oid];
	my $qsp = PublicInbox::Qspawn->new($cmd);
	my $env = $ctx->{env};
	$env->{'qspawn.wcb'} = delete $ctx->{-wcb};
	$qsp->psgi_return($env, undef, \&stream_blob_parse_hdr, $ctx);
}

sub show_other_result ($$) {
	my ($bref, $ctx) = @_;
	my ($qsp, $logref) = delete @$ctx{qw(-qsp -logref)};
	if (my $err = $qsp->{err}) {
		utf8::decode($$err);
		$$logref .= "git show error: $err";
		return html_page($ctx, 500, $logref);
	}
	my $l = PublicInbox::Linkify->new;
	utf8::decode($$bref);
	$$bref = '<pre>'. $l->to_html($$bref);
	$$bref .= '</pre><hr>' . $$logref;
	html_page($ctx, 200, $bref);
}

sub show_other ($$$$) {
	my ($ctx, $res, $logref, $fn) = @_;
	my ($git, $oid, $type, $size) = @$res;
	if ($size > $MAX_SIZE) {
		$$logref = "$oid is too big to show\n" . $$logref;
		return html_page($ctx, 200, $logref);
	}
	my $cmd = ['git', "--git-dir=$git->{git_dir}",
		qw(show --encoding=UTF-8 --no-color --no-abbrev), $oid ];
	my $qsp = PublicInbox::Qspawn->new($cmd);
	my $env = $ctx->{env};
	$ctx->{-qsp} = $qsp;
	$ctx->{-logref} = $logref;
	$qsp->psgi_qx($env, undef, \&show_other_result, $ctx);
}

# user_cb for SolverGit, called as: user_cb->($result_or_error, $uarg)
sub solve_result {
	my ($res, $ctx) = @_;
	my ($log, $hints, $fn) = delete @$ctx{qw(log hints fn)};

	unless (seek($log, 0, 0)) {
		$ctx->{env}->{'psgi.errors'}->print("seek(log): $!\n");
		return html_page($ctx, 500, \'seek error');
	}
	$log = do { local $/; <$log> };

	my $ref = ref($res);
	my $l = PublicInbox::Linkify->new;
	$log = '<pre>debug log:</pre><hr /><pre>' .
		$l->to_html($log) . '</pre>';

	$res or return html_page($ctx, 404, \$log);
	$ref eq 'ARRAY' or return html_page($ctx, 500, \$log);

	my ($git, $oid, $type, $size, $di) = @$res;
	return show_other($ctx, $res, \$log, $fn) if $type ne 'blob';
	my $path = to_filename($di->{path_b} // $hints->{path_b} // 'blob');
	my $raw_link = "(<a\nhref=$path>raw</a>)";
	if ($size > $MAX_SIZE) {
		return stream_large_blob($ctx, $res, \$log, $fn) if defined $fn;
		$log = "<pre><b>Too big to show, download available</b>\n" .
			"$oid $type $size bytes $raw_link</pre>" . $log;
		return html_page($ctx, 200, \$log);
	}

	my $blob = $git->cat_file($oid);
	if (!$blob) { # WTF?
		my $e = "Failed to retrieve generated blob ($oid)";
		$ctx->{env}->{'psgi.errors'}->print("$e ($git->{git_dir})\n");
		$log = "<pre><b>$e</b></pre>" . $log;
		return html_page($ctx, 500, \$log);
	}

	my $bin = index(substr($$blob, 0, $BIN_DETECT), "\0") >= 0;
	if (defined $fn) {
		my $h = [ 'Content-Length', $size, 'Content-Type' ];
		push(@$h, ($bin ? 'application/octet-stream' : 'text/plain'));
		return delete($ctx->{-wcb})->([200, $h, [ $$blob ]]);
	}

	if ($bin) {
		$log = "<pre>$oid $type $size bytes (binary)" .
			" $raw_link</pre>" . $log;
		return html_page($ctx, 200, \$log);
	}

	# TODO: detect + convert to ensure validity
	utf8::decode($$blob);
	my $nl = ($$blob =~ s/\r?\n/\n/sg);
	my $pad = length($nl);

	$l->linkify_1($$blob);
	my $ok = $hl->do_hl($blob, $path) if $hl;
	if ($ok) {
		$blob = $ok;
	} else {
		$$blob = ascii_html($$blob);
	}

	# using some of the same CSS class names and ids as cgit
	$log = "<pre>$oid $type $size bytes $raw_link</pre>" .
		"<hr /><table\nclass=blob>".
		"<tr><td\nclass=linenumbers><pre>" . join('', map {
			sprintf("<a id=n$_ href=#n$_>% ${pad}u</a>\n", $_)
		} (1..$nl)) . '</pre></td>' .
		'<td><pre> </pre></td>'. # pad for non-CSS users
		"<td\nclass=lines><pre\nstyle='white-space:pre'><code>" .
		$l->linkify_2($$blob) .
		'</code></pre></td></tr></table>' . $log;

	html_page($ctx, 200, \$log);
}

# GET /$INBOX/$GIT_OBJECT_ID/s/
# GET /$INBOX/$GIT_OBJECT_ID/s/$FILENAME
sub show ($$;$) {
	my ($ctx, $oid_b, $fn) = @_;
	my $qp = $ctx->{qp};
	my $hints = $ctx->{hints} = {};
	while (my ($from, $to) = each %QP_MAP) {
		defined(my $v = $qp->{$from}) or next;
		$hints->{$to} = $v if $v ne '';
	}

	$ctx->{'log'} = tmpfile("solve.$oid_b");
	$ctx->{fn} = $fn;
	my $solver = PublicInbox::SolverGit->new($ctx->{-inbox},
						\&solve_result, $ctx);
	# PSGI server will call this immediately and give us a callback (-wcb)
	sub {
		$ctx->{-wcb} = $_[0]; # HTTP write callback
		$solver->solve($ctx->{env}, $ctx->{log}, $oid_b, $hints);
	};
}

1;
