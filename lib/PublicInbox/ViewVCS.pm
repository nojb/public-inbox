# Copyright (C) 2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# show any VCS object, similar to "git show"
package PublicInbox::ViewVCS;
use strict;
use warnings;
use Encode qw(find_encoding);
use PublicInbox::SolverGit;
use PublicInbox::WwwStream;
use PublicInbox::Linkify;
use PublicInbox::Hval qw(ascii_html);
my %QP_MAP = ( A => 'oid_a', B => 'oid_b', a => 'path_a', b => 'path_b' );
my $max_size = 1024 * 1024; # TODO: configurable
my $enc_utf8 = find_encoding('UTF-8');

sub html_page ($$$) {
	my ($ctx, $code, $strref) = @_;
	$ctx->{-upfx} = '../'; # from "/$INBOX/$OID/s"
	PublicInbox::WwwStream->response($ctx, $code, sub {
		my ($nr, undef) =  @_;
		$nr == 1 ? $$strref : undef;
	});
}

sub show ($$;$) {
	my ($ctx, $oid_b, $fn) = @_;
	my $ibx = $ctx->{-inbox};
	my $inboxes = [ $ibx ];
	my $solver = PublicInbox::SolverGit->new($ibx->{-repo_objs}, $inboxes);
	my $qp = $ctx->{qp};
	my $hints = {};
	while (my ($from, $to) = each %QP_MAP) {
		defined(my $v = $qp->{$from}) or next;
		$hints->{$to} = $v;
	}

	open my $log, '+>', undef or die "open: $!";
	my $res = $solver->solve($log, $oid_b, $hints);

	seek($log, 0, 0) or die "seek: $!";
	$log = do { local $/; <$log> };

	my $l = PublicInbox::Linkify->new;
	$l->linkify_1($log);
	$log = '<pre>debug log:</pre><hr /><pre>' .
		$l->linkify_2(ascii_html($log)) . '</pre>';

	$res or return html_page($ctx, 404, \$log);

	my ($git, $oid, $type, $size, $di) = @$res;
	if ($size > $max_size) {
		# TODO: stream the raw file if it's gigantic, at least
		$log = '<pre><b>Too big to show</b></pre>' . $log;
		return html_page($ctx, 500, \$log);
	}

	my $blob = $git->cat_file($oid);
	if (!$blob) { # WTF?
		my $e = "Failed to retrieve generated blob ($oid)";
		$ctx->{env}->{'psgi.errors'}->print("$e ($git->{git_dir})\n");
		$log = "<pre><b>$e</b></pre>" . $log;
		return html_page($ctx, 500, \$log);
	}

	if (index($$blob, "\0") >= 0) {
		$log = "<pre>$oid $type $size bytes (binary)</pre>" . $log;
		return html_page($ctx, 200, \$log);
	}

	$$blob = $enc_utf8->decode($$blob);
	my $nl = ($$blob =~ tr/\n/\n/);
	my $pad = length($nl);

	# using some of the same CSS class names and ids as cgit
	$log = "<pre>$oid $type $size bytes</pre><hr /><table\nclass=blob>".
		"<tr><td\nclass=linenumbers><pre>" . join('', map {
			sprintf("<a id=n$_ href=#n$_>% ${pad}u</a>\n", $_)
		} (1..$nl)) . '</pre></td>' .
		'<td><pre> </pre></td>'. # pad for non-CSS users
		"<td\nclass=lines><pre><code>" .  ascii_html($$blob) .
		'</pre></td></tr></table>' . $log;

	html_page($ctx, 200, \$log);
}

1;
