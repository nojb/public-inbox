# Copyright (C) 2013-2015 all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
#
# Used for generating Atom feeds for web-accessible mailing list archives.
package PublicInbox::Feed;
use strict;
use warnings;
use Email::Address;
use Email::MIME;
use Date::Parse qw(strptime);
use PublicInbox::Hval;
use PublicInbox::Git;
use PublicInbox::View;
use PublicInbox::MID qw/mid_clean mid2path/;
use POSIX qw/strftime/;
use constant {
	DATEFMT => '%Y-%m-%dT%H:%M:%SZ', # Atom standard
	MAX_PER_PAGE => 25, # this needs to be tunable
};

use Encode qw/find_encoding/;
my $enc_utf8 = find_encoding('UTF-8');

# main function
sub generate {
	my ($ctx) = @_;
	sub { emit_atom($_[0], $ctx) };
}

sub generate_thread_atom {
	my ($ctx) = @_;
	sub { emit_atom_thread($_[0], $ctx) };
}

sub generate_html_index {
	my ($ctx) = @_;
	sub { emit_html_index($_[0], $ctx) };
}

# private subs

sub title_tag {
	my ($title) = @_;
	# try to avoid the type attribute in title:
	$title = PublicInbox::Hval->new_oneline($title)->as_html;
	my $type = index($title, '&') >= 0 ? "\ntype=\"html\"" : '';
	"<title$type>$title</title>";
}

sub atom_header {
	my ($feed_opts, $title) = @_;

	$title = title_tag($feed_opts->{description}) unless (defined $title);

	qq(<?xml version="1.0" encoding="us-ascii"?>\n) .
	qq{<feed\nxmlns="http://www.w3.org/2005/Atom">} .
	qq{$title} .
	qq(<link\nhref="$feed_opts->{url}"/>) .
	qq(<link\nrel="self"\nhref="$feed_opts->{atomurl}"/>) .
	qq(<id>mailto:$feed_opts->{id_addr}</id>);
}

sub emit_atom {
	my ($cb, $ctx) = @_;
	my $fh = $cb->([ 200, ['Content-Type' => 'application/atom+xml']]);
	my $max = $ctx->{max} || MAX_PER_PAGE;
	my $feed_opts = get_feedopts($ctx);
	my $x = atom_header($feed_opts);
	my $git = $ctx->{git} ||= PublicInbox::Git->new($ctx->{git_dir});
	each_recent_blob($ctx, sub {
		my ($path, undef, $ts) = @_;
		if (defined $x) {
			$fh->write($x . feed_updated(undef, $ts));
			$x = undef;
		}
		add_to_feed($feed_opts, $fh, $path, $git);
	});
	end_feed($fh);
}

sub _no_thread {
	my ($cb) = @_;
	my $fh = $cb->([404, ['Content-Type' => 'text/plain']]);
	$fh->write("No feed found for thread\n");
	$fh->close;
}

sub end_feed {
	my ($fh) = @_;
	Email::Address->purge_cache;
	$fh->write('</feed>');
	$fh->close;
}

sub emit_atom_thread {
	my ($cb, $ctx) = @_;
	my $res = $ctx->{srch}->get_thread($ctx->{mid});
	return _no_thread($cb) unless $res->{total};
	my $fh = $cb->([200, ['Content-Type' => 'application/atom+xml']]);
	my $feed_opts = get_feedopts($ctx);

	my $html_url = $feed_opts->{atomurl} = $ctx->{self_url};
	$html_url =~ s!/t\.atom\z!/!;
	$feed_opts->{url} = $html_url;
	$feed_opts->{emit_header} = 1;

	my $git = $ctx->{git} ||= PublicInbox::Git->new($ctx->{git_dir});
	foreach my $msg (@{$res->{msgs}}) {
		add_to_feed($feed_opts, $fh, mid2path($msg->mid), $git);
	}
	end_feed($fh);
}

sub emit_html_index {
	my ($cb, $ctx) = @_;
	my $fh = $cb->([200,['Content-Type'=>'text/html; charset=UTF-8']]);

	my $max = $ctx->{max} || MAX_PER_PAGE;
	my $feed_opts = get_feedopts($ctx);

	my $title = $feed_opts->{description} || '';
	$title = PublicInbox::Hval->new_oneline($title)->as_html;
	my $atom_url = $feed_opts->{atomurl};
	my ($footer, $param, $last);
	my $state = { ctx => $ctx, seen => {}, anchor_idx => 0 };
	my $srch = $ctx->{srch};

	my $top = "<b>$title</b> (<a\nhref=\"$atom_url\">Atom feed</a>)";

	if ($srch) {
		$top = qq{<form\naction=""><tt>$top} .
			  qq{ <input\nname=q\ntype=text />} .
			  qq{<input\ntype=submit\nvalue=search />} .
			  qq{</tt></form>} .
			  PublicInbox::Hval::PRE;
	} else {
		$top = PublicInbox::Hval::PRE . $top . "\n";
	}

	$fh->write("<html><head><title>$title</title>" .
		   "<link\nrel=alternate\ntitle=\"Atom feed\"\n".
		   "href=\"$atom_url\"\ntype=\"application/atom+xml\"/>" .
		   "</head><body>$top");

	# if the 'r' query parameter is given, it is a legacy permalink
	# which we must continue supporting:
	my $cgi = $ctx->{cgi};
	if ($cgi && !$cgi->param('r') && $srch) {
		$state->{srch} = $srch;
		$last = PublicInbox::View::emit_index_topics($state, $fh);
		$param = 'o';
	} else {
		$last = emit_index_nosrch($ctx, $state, $fh);
		$param = 'r';
	}
	$footer = nav_footer($cgi, $last, $feed_opts, $state, $param);
	if ($footer) {
		my $list_footer = $ctx->{footer};
		$footer .= "\n\n" . $list_footer if $list_footer;
		$footer = "<hr /><pre>$footer</pre>";
	}
	$fh->write("$footer</body></html>");
	$fh->close;
}

sub emit_index_nosrch {
	my ($ctx, $state, $fh) = @_;
	my $git = $ctx->{git} ||= PublicInbox::Git->new($ctx->{git_dir});
	my (undef, $last) = each_recent_blob($ctx, sub {
		my ($path, $commit, $ts, $u, $subj) = @_;
		$state->{first} ||= $commit;

		my $mime = do_cat_mail($git, $path) or return 0;
		PublicInbox::View::index_entry($fh, $mime, 0, $state);
		1;
	});
	Email::Address->purge_cache;
	$last;
}

sub nav_footer {
	my ($cgi, $last, $feed_opts, $state, $param) = @_;
	$cgi or return '';
	my $old_r = $cgi->param($param);
	my $head = '    ';
	my $next = '    ';
	my $first = $state->{first};
	my $anchor = $state->{anchor_idx};

	if ($last) {
		$next = qq!<a\nhref="?$param=$last">next</a>!;
	}
	if ($old_r) {
		$head = $cgi->path_info;
		$head = qq!<a\nhref="$head">head</a>!;
	}
	my $atom = "<a\nhref=\"$feed_opts->{atomurl}\">Atom</a>";
	"<a\nname=\"s$anchor\">page:</a> $next $head $atom";
}

sub each_recent_blob {
	my ($ctx, $cb) = @_;
	my $max = $ctx->{max} || MAX_PER_PAGE;
	my $hex = '[a-f0-9]';
	my $addmsg = qr!^:000000 100644 \S+ \S+ A\t(${hex}{2}/${hex}{38})$!;
	my $delmsg = qr!^:100644 000000 \S+ \S+ D\t(${hex}{2}/${hex}{38})$!;
	my $refhex = qr/(?:HEAD|${hex}{4,40})(?:~\d+)?/;
	my $cgi = $ctx->{cgi};

	# revision ranges may be specified
	my $range = 'HEAD';
	my $r = $cgi->param('r') if $cgi;
	if ($r && ($r =~ /\A(?:$refhex\.\.)?$refhex\z/o)) {
		$range = $r;
	}

	# get recent messages
	# we could use git log -z, but, we already know ssoma will not
	# leave us with filenames with spaces in them..
	my $git = $ctx->{git} ||= PublicInbox::Git->new($ctx->{git_dir});
	my $log = $git->popen(qw/log --no-notes --no-color --raw -r
				--abbrev=16 --abbrev-commit/,
				"--format=%h%x00%ct%x00%an%x00%s%x00",
				$range);
	my %deleted; # only an optimization at this point
	my $last;
	my $nr = 0;
	my ($cur_commit, $first_commit, $last_commit);
	my ($ts, $subj, $u);
	while (defined(my $line = <$log>)) {
		if ($line =~ /$addmsg/o) {
			my $add = $1;
			next if $deleted{$add}; # optimization-only
			$nr += $cb->($add, $cur_commit, $ts, $u, $subj);
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
		while (my $line = <$log>) {
			if ($line =~ /^(${hex}{7,40})/o) {
				$last_commit = $1;
				last;
			}
		}
	}

	close $log; # we may EPIPE here
	# for pagination
	($first_commit, $last_commit);
}

# private functions below
sub get_feedopts {
	my ($ctx) = @_;
	my $pi_config = $ctx->{pi_config};
	my $listname = $ctx->{listname};
	my $cgi = $ctx->{cgi};
	my %rv;
	if (open my $fh, '<', "$ctx->{git_dir}/description") {
		chomp($rv{description} = <$fh>);
		close $fh;
	} else {
		$rv{description} = '($GIT_DIR/description missing)';
	}

	if ($pi_config && defined $listname && $listname ne '') {
		my $addr = $pi_config->get($listname, 'address') || "";
		$rv{address} = $addr;
		$addr = $addr->[0] if ref($addr);
		$rv{id_addr} = $addr;
	}
	$rv{id_addr} ||= 'public-inbox@example.com';

	my $url_base;
	if ($cgi) {
		my $base;
		if (ref($cgi) eq 'CGI') {
			$base = $cgi->url(-base);
		} else {
			$base = $cgi->base->as_string;
			$base =~ s!/\z!!;
		}
		$url_base = "$base/$listname";
		if (my $mid = $ctx->{mid}) { # per-thread feed:
			$rv{atomurl} = "$url_base/$mid/t.atom";
		} else {
			$rv{atomurl} = "$url_base/new.atom";
		}
	} else {
		$url_base = "http://example.com";
		$rv{atomurl} = "$url_base/new.atom";
	}
	$rv{url} ||= "$url_base/";
	$rv{midurl} = "$url_base/";

	\%rv;
}

sub mime_header {
	my ($mime, $name) = @_;
	PublicInbox::Hval->new_oneline($mime->header($name))->raw;
}

sub feed_updated {
	my ($date, $ts) = @_;
	my @t = eval { strptime($date) } if defined $date;
	@t = gmtime($ts || time) unless scalar @t;

	'<updated>' . strftime(DATEFMT, @t) . '</updated>';
}

# returns 0 (skipped) or 1 (added)
sub add_to_feed {
	my ($feed_opts, $fh, $add, $git) = @_;

	my $mime = do_cat_mail($git, $add) or return 0;
	my $url = $feed_opts->{url};
	my $midurl = $feed_opts->{midurl};

	my $header_obj = $mime->header_obj;
	my $mid = $header_obj->header('Message-ID');
	defined $mid or return 0;
	$mid = PublicInbox::Hval->new_msgid($mid);
	my $href = $mid->as_href;
	my $content = PublicInbox::View->feed_entry($mime, "$midurl$href/f/");
	defined($content) or return 0;
	$mime = undef;

	my $date = $header_obj->header('Date');
	my $updated = feed_updated($date);

	my $title = mime_header($header_obj, 'Subject') or return 0;
	$title = title_tag($title);

	my $from = mime_header($header_obj, 'From') or return 0;
	my @from = Email::Address->parse($from) or return 0;
	my $name = PublicInbox::Hval->new_oneline($from[0]->name)->as_html;
	my $email = $from[0]->address;
	$email = PublicInbox::Hval->new_oneline($email)->as_html;

	if (delete $feed_opts->{emit_header}) {
		$fh->write(atom_header($feed_opts, $title) . $updated);
	}
	$fh->write("<entry><author><name>$name</name><email>$email</email>" .
		   "</author>$title$updated" .
		   qq{<content\ntype="xhtml">} .
		   qq{<div\nxmlns="http://www.w3.org/1999/xhtml">});
	$fh->write($content);

	$add =~ tr!/!!d;
	my $h = '[a-f0-9]';
	my (@uuid5) = ($add =~ m!\A($h{8})($h{4})($h{4})($h{4})($h{12})!o);
	my $id = 'urn:uuid:' . join('-', @uuid5);
	$fh->write(qq!</div></content><link\nhref="$midurl$href/"/>!.
		   "<id>$id</id></entry>");
	1;
}

sub do_cat_mail {
	my ($git, $path) = @_;
	my $mime = eval {
		my $str = $git->cat_file("HEAD:$path");
		Email::MIME->new($str);
	};
	$@ ? undef : $mime;
}

1;
