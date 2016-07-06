# Copyright (C) 2013-2015 all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
#
# Used for generating Atom feeds for web-accessible mailing list archives.
package PublicInbox::Feed;
use strict;
use warnings;
use Email::MIME;
use Date::Parse qw(strptime);
use PublicInbox::Hval qw/ascii_html/;
use PublicInbox::Git;
use PublicInbox::View;
use PublicInbox::MID qw/mid_clean mid2path/;
use PublicInbox::Address;
use POSIX qw/strftime/;
use constant {
	DATEFMT => '%Y-%m-%dT%H:%M:%SZ', # Atom standard
	MAX_PER_PAGE => 25, # this needs to be tunable
};

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

sub new_html {
	my ($ctx) = @_;
	my @paths;
	my (undef, $last) = each_recent_blob($ctx, sub {
		my ($path, $commit, $ts, $u, $subj) = @_;
		$ctx->{first} ||= $commit;
		push @paths, $path;
	});
	if (!@paths) {
		return [404, ['Content-Type', 'text/plain'],
			["No messages, yet\n"] ];
	}
	$ctx->{-html_tip} = '<pre>';
	$ctx->{-upfx} = '';
	PublicInbox::WwwStream->response($ctx, 200, sub {
		while (my $path = shift @paths) {
			my $m = do_cat_mail($ctx->{-inbox}, $path) or next;
			my $more = scalar @paths;
			my $s = PublicInbox::View::index_entry($m, $ctx, $more);
			$s .= '</pre>' unless $more;
			return $s;
		}
		undef;
	});
}

# private subs

sub title_tag {
	my ($title) = @_;
	$title =~ tr/\t\n / /s; # squeeze spaces
	# try to avoid the type attribute in title:
	$title = ascii_html($title);
	my $type = index($title, '&') >= 0 ? "\ntype=\"html\"" : '';
	"<title$type>$title</title>";
}

sub atom_header {
	my ($feed_opts, $title) = @_;

	$title = title_tag($feed_opts->{description}) unless (defined $title);

	qq(<?xml version="1.0" encoding="us-ascii"?>\n) .
	qq{<feed\nxmlns="http://www.w3.org/2005/Atom">} .
	qq{$title} .
	qq(<link\nrel="alternate"\ntype="text/html") .
		qq(\nhref="$feed_opts->{url}"/>) .
	qq(<link\nrel="self"\nhref="$feed_opts->{atomurl}"/>) .
	qq(<id>mailto:$feed_opts->{id_addr}</id>);
}

sub emit_atom {
	my ($cb, $ctx) = @_;
	my $feed_opts = get_feedopts($ctx);
	my $fh = $cb->([ 200, ['Content-Type' => 'application/atom+xml']]);
	my $max = $ctx->{max} || MAX_PER_PAGE;
	my $x = atom_header($feed_opts);
	my $ibx = $ctx->{-inbox};
	each_recent_blob($ctx, sub {
		my ($path, undef, $ts) = @_;
		if (defined $x) {
			$fh->write($x . feed_updated(undef, $ts));
			$x = undef;
		}
		my $s = feed_entry($feed_opts, $path, $ibx) or return 0;
		$fh->write($s);
		1;
	});
	end_feed($fh);
}

sub _no_thread {
	my ($cb) = @_;
	$cb->([404, ['Content-Type', 'text/plain'],
		["No feed found for thread\n"]]);
}

sub end_feed {
	my ($fh) = @_;
	$fh->write('</feed>');
	$fh->close;
}

sub emit_atom_thread {
	my ($cb, $ctx) = @_;
	my $mid = $ctx->{mid};
	my $res = $ctx->{srch}->get_thread($mid);
	return _no_thread($cb) unless $res->{total};
	my $feed_opts = get_feedopts($ctx);
	my $fh = $cb->([200, ['Content-Type' => 'application/atom+xml']]);
	my $ibx = $ctx->{-inbox};
	my $html_url = $ibx->base_url($ctx->{env});
	$html_url .= PublicInbox::Hval->new_msgid($mid)->as_href;

	$feed_opts->{url} = $html_url;
	$feed_opts->{emit_header} = 1;

	foreach my $msg (@{$res->{msgs}}) {
		my $s = feed_entry($feed_opts, mid2path($msg->mid), $ibx);
		$fh->write($s) if defined $s;
	}
	end_feed($fh);
}

sub _html_index_top {
	my ($feed_opts, $srch) = @_;

	my $title = ascii_html($feed_opts->{description} || '');
	my $top = "<b>$title</b> (<a\nhref=\"new.atom\">Atom feed</a>)";
	if ($srch) {
		$top = qq{<form\naction=""><pre>$top} .
			  qq{ <input\nname=q\ntype=text />} .
			  qq{<input\ntype=submit\nvalue=search />} .
			  q{</pre></form><pre>}
	} else {
		$top = '<pre>' . $top . "\n";
	}

	"<html><head><title>$title</title>" .
		"<link\nrel=alternate\ntitle=\"Atom feed\"\n".
		"href=\"new.atom\"\ntype=\"application/atom+xml\"/>" .
		PublicInbox::Hval::STYLE .
		"</head><body>$top";
}

sub emit_html_index {
	my ($res, $ctx) = @_;
	my $feed_opts = get_feedopts($ctx);
	my $fh = $res->([200,['Content-Type'=>'text/html; charset=UTF-8']]);

	my $max = $ctx->{max} || MAX_PER_PAGE;
	$ctx->{-upfx} = '';

	my ($footer, $param, $last);
	$ctx->{seen} = {};
	$ctx->{anchor_idx} = 0;
	$ctx->{fh} = $fh;
	my $srch = $ctx->{srch};
	$fh->write(_html_index_top($feed_opts, $srch));

	# if the 'r' query parameter is given, it is a legacy permalink
	# which we must continue supporting:
	my $qp = $ctx->{qp};
	if ($qp && !$qp->{r} && $srch) {
		$last = PublicInbox::View::emit_index_topics($ctx);
		$param = 'o';
	} else {
		$last = emit_index_nosrch($ctx);
		$param = 'r';
	}
	$footer = nav_footer($ctx, $last, $feed_opts, $param);
	if ($footer) {
		my $list_footer = $ctx->{footer};
		$footer .= "\n\n" . $list_footer if $list_footer;
		$footer = "<hr><pre>$footer</pre>";
	}
	$fh->write("$footer</body></html>");
	$fh->close;
}

sub emit_index_nosrch {
	my ($ctx) = @_;
	my $ibx = $ctx->{-inbox};
	my $fh = $ctx->{fh};
	my (undef, $last) = each_recent_blob($ctx, sub {
		my ($path, $commit, $ts, $u, $subj) = @_;
		$ctx->{first} ||= $commit;

		my $mime = do_cat_mail($ibx, $path) or return 0;
		$fh->write(PublicInbox::View::index_entry($mime, $ctx, 1));
		1;
	});
	$last;
}

sub nav_footer {
	my ($ctx, $last, $feed_opts, $param) = @_;
	my $qp = $ctx->{qp} or return '';
	my $old_r = $qp->{$param};
	my $head = '    ';
	my $next = '    ';
	my $first = $ctx->{first};
	my $anchor = $ctx->{anchor_idx};

	if ($last) {
		$next = qq!<a\nhref="?$param=$last"\nrel=next>next</a>!;
	}
	if ($old_r) {
		$head = $ctx->{env}->{PATH_INFO};
		$head = qq!<a\nhref="$head">head</a>!;
	}
	my $atom = "<a\nhref=\"$feed_opts->{atomurl}\">Atom feed</a>";
	"<a\nname=\"s$anchor\">page:</a> $next $head $atom";
}

sub each_recent_blob {
	my ($ctx, $cb) = @_;
	my $max = $ctx->{max} || MAX_PER_PAGE;
	my $hex = '[a-f0-9]';
	my $addmsg = qr!^:000000 100644 \S+ \S+ A\t(${hex}{2}/${hex}{38})$!;
	my $delmsg = qr!^:100644 000000 \S+ \S+ D\t(${hex}{2}/${hex}{38})$!;
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
	my $log = $ctx->{-inbox}->git->popen(qw/log
				--no-notes --no-color --raw -r
				--abbrev=16 --abbrev-commit/,
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

# private functions below
sub get_feedopts {
	my ($ctx) = @_;
	my $pi_config = $ctx->{pi_config};
	my $inbox = $ctx->{inbox};
	my $obj = $ctx->{-inbox};
	my %rv = ( description => $obj->description );

	$rv{address} = $obj->{address};
	$rv{id_addr} = $obj->{-primary_address};
	my $url_base = $obj->base_url($ctx->{env});
	if (my $mid = $ctx->{mid}) { # per-thread feed:
		$rv{atomurl} = "$url_base$mid/t.atom";
	} else {
		$rv{atomurl} = $url_base."new.atom";
	}
	$rv{url} ||= $url_base;
	$rv{midurl} = $url_base;

	\%rv;
}

sub feed_updated {
	my ($date, $ts) = @_;
	my @t = eval { strptime($date) } if defined $date;
	@t = gmtime($ts || time) unless scalar @t;

	'<updated>' . strftime(DATEFMT, @t) . '</updated>';
}

# returns undef or string
sub feed_entry {
	my ($feed_opts, $add, $ibx) = @_;

	my $mime = do_cat_mail($ibx, $add) or return;
	my $url = $feed_opts->{url};
	my $midurl = $feed_opts->{midurl};

	my $header_obj = $mime->header_obj;
	my $mid = $header_obj->header_raw('Message-ID');
	defined $mid or return;
	$mid = PublicInbox::Hval->new_msgid($mid);
	my $href = $midurl . $mid->as_href . '/';

	my $date = $header_obj->header('Date');
	my $updated = feed_updated($date);

	my $title = $header_obj->header('Subject');
	defined $title or return;
	$title = title_tag($title);

	my $from = $header_obj->header('From') or return;
	my ($email) = PublicInbox::Address::emails($from);
	my $name = join(', ',PublicInbox::Address::names($from));
	$name = ascii_html($name);
	$email = ascii_html($email);

	my $s = '';
	if (delete $feed_opts->{emit_header}) {
		$s .= atom_header($feed_opts, $title) . $updated;
	}
	$s .= "<entry><author><name>$name</name><email>$email</email>" .
		"</author>$title$updated" .
		qq{<content\ntype="xhtml">} .
		qq{<div\nxmlns="http://www.w3.org/1999/xhtml">} .
		qq(<pre\nstyle="white-space:pre-wrap">) .
		PublicInbox::View::multipart_text_as_html($mime, $href) .
		'</pre>';

	$add =~ tr!/!!d;
	my $h = '[a-f0-9]';
	my (@uuid5) = ($add =~ m!\A($h{8})($h{4})($h{4})($h{4})($h{12})!o);
	my $id = 'urn:uuid:' . join('-', @uuid5);
	$s .= qq!</div></content><link\nhref="$href"/>!.
		"<id>$id</id></entry>";
}

sub do_cat_mail {
	my ($ibx, $path) = @_;
	my $mime = eval { $ibx->msg_by_path($path) } or return;
	Email::MIME->new($mime);
}

1;
