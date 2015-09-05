# Copyright (C) 2015 all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
package PublicInbox::ExtMsg;
use strict;
use warnings;
use URI::Escape qw(uri_escape_utf8);
use PublicInbox::Hval;
use PublicInbox::MID qw/mid2path/;

# TODO: user-configurable
our @EXT_URL = (
	'http://mid.gmane.org/%s',
	'https://lists.debian.org/msgid-search/%s',
	'http://mid.mail-archive.com/%s',
	'http://marc.info/?i=%s',
);

sub ext_msg {
	my ($ctx) = @_;
	my $pi_config = $ctx->{pi_config};
	my $listname = $ctx->{listname};
	my $mid = $ctx->{mid};

	eval { require PublicInbox::Search };
	my $have_xap = $@ ? 0 : 1;
	my (@nox, @pfx);

	foreach my $k (keys %$pi_config) {
		$k =~ /\Apublicinbox\.([A-Z0-9a-z-]+)\.url\z/ or next;
		my $list = $1;
		next if $list eq $listname;

		my $git_dir = $pi_config->{"publicinbox.$list.mainrepo"};
		defined $git_dir or next;

		my $url = $pi_config->{"publicinbox.$list.url"};
		defined $url or next;

		$url =~ s!/+\z!!;

		# try to find the URL with Xapian to avoid forking
		if ($have_xap) {
			my $s;
			my $doc_id = eval {
				$s = PublicInbox::Search->new($git_dir);
				$s->find_unique_doc_id('mid', $mid);
			};
			if ($@) {
				# xapian not configured for this repo
			} else {
				# maybe we found it!
				return r302($url, $mid) if (defined $doc_id);

				# no point in trying the fork fallback if we
				# know Xapian is up-to-date but missing the
				# message in the current repo
				push @pfx, { srch => $s, url => $url };
				next;
			}
		}

		# queue up for forking after we've tried Xapian on all of them
		push @nox, { git_dir => $git_dir, url => $url };
	}

	# Xapian not installed or configured for some repos
	my $path = "HEAD:" . mid2path($mid);

	foreach my $n (@nox) {
		my @cmd = ('git', "--git-dir=$n->{git_dir}", 'cat-file',
			   '-t', $path);
		my $pid = open my $fh, '-|';
		defined $pid or die "fork failed: $!\n";

		if ($pid == 0) {
			open STDERR, '>', '/dev/null'; # ignore errors
			exec @cmd or die "exec failed: $!\n";
		} else {
			my $type = eval { local $/; <$fh> };
			close $fh;
			if ($? == 0 && $type eq "blob\n") {
				return r302($n->{url}, $mid);
			}
		}
	}

	# fall back to partial MID matching
	my $n_partial = 0;
	my @partial;
	if ($have_xap) {
		my $cgi = $ctx->{cgi};
		my $url = ref($cgi) eq 'CGI' ? $cgi->url(-base) . '/'
					: $cgi->base->as_string;
		$url .= $listname;
		unshift @pfx, { srch => $ctx->{srch}, url => $url };
		foreach my $pfx (@pfx) {
			my $srch = delete $pfx->{srch} or next;
			if (my $res = $srch->mid_prefix($mid)) {
				$n_partial += scalar(@$res);
				$pfx->{res} = $res;
				push @partial, $pfx;
			}
		}
	}
	my $code = 404;
	my $h = PublicInbox::Hval->new_msgid($mid, 1);
	my $href = $h->as_href;
	my $html = $h->as_html;
	my $title = "Message-ID &lt;$html&gt; not found";
	my $s = "<html><head><title>$title</title>" .
		"</head><body><pre><b>$title</b>\n";

	if ($n_partial) {
		$code = 300;
		$s.= "\nPartial matches found:\n\n";
		foreach my $pfx (@partial) {
			my $u = $pfx->{url};
			foreach my $m (@{$pfx->{res}}) {
				$h = PublicInbox::Hval->new($m);
				$href = $h->as_href;
				$html = $h->as_html;
				$s .= qq{<a\nhref="$u/$href/">$u/$html/</a>\n};
			}
		}
	}

	# Fall back to external repos if configured
	if (@EXT_URL) {
		$code = 300;
		$s .= "\nPerhaps try an external site:\n\n";
		foreach my $u (@EXT_URL) {
			my $r = sprintf($u, $href);
			my $t = sprintf($u, $html);
			$s .= qq{<a\nhref="$r">$t</a>\n};
		}
	}
	$s .= '</pre></body></html>';

	[300, ['Content-Type'=>'text/html; charset=UTF-8'], [$s]];
}

# Redirect to another public-inbox which is mapped by $pi_config
sub r302 {
	my ($url, $mid) = @_;
	$url .= '/' . uri_escape_utf8($mid) . '/';
	[ 302,
	  [ 'Location' => $url, 'Content-Type' => 'text/plain' ],
	  [ "Redirecting to\n$url\n" ] ]
}

1;
