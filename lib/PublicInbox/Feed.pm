# Copyright (C) 2013, Eric Wong <normalperson@yhbt.net> and all contributors
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
package PublicInbox::Feed;
use strict;
use warnings;
use Email::Address;
use Email::MIME;
use Date::Parse qw(strptime str2time);
use PublicInbox::Hval;
use PublicInbox::GitCatFile;
use PublicInbox::View;
use constant {
	DATEFMT => '%Y-%m-%dT%H:%M:%SZ', # atom standard
	MAX_PER_PAGE => 25, # this needs to be tunable
	PRE_WRAP => "<pre\nstyle=\"white-space:pre-wrap\">",
};

# main function
sub generate {
	my ($class, $args) = @_;
	require XML::Atom::SimpleFeed;
	require POSIX;
	my $max = $args->{max} || MAX_PER_PAGE;

	my $feed_opts = get_feedopts($args);
	my $addr = $feed_opts->{address};
	$addr = $addr->[0] if ref($addr);
	my $feed = XML::Atom::SimpleFeed->new(
		title => $feed_opts->{description} || "unnamed feed",
		link => $feed_opts->{url} || "http://example.com/",
		link => {
			rel => 'self',
			href => $feed_opts->{atomurl} ||
				"http://example.com/atom.xml",
		},
		id => 'mailto:' . ($addr || 'public-inbox@example.com'),
		updated => POSIX::strftime(DATEFMT, gmtime),
	);

	my $git = PublicInbox::GitCatFile->new($args->{git_dir});
	each_recent_blob($args, sub {
		my ($add) = @_;
		add_to_feed($feed_opts, $feed, $add, $git);
	});
	$git = undef; # destroy pipes
	Email::Address->purge_cache;
	$feed->as_string;
}

sub generate_html_index {
	my ($class, $args) = @_;
	require PublicInbox::Thread;

	my $max = $args->{max} || MAX_PER_PAGE;
	my $feed_opts = get_feedopts($args);

	my $title = $feed_opts->{description} || '';
	$title = PublicInbox::Hval->new_oneline($title)->as_html;

	my @messages;
	my $git_dir = $args->{git_dir};
	my $git = PublicInbox::GitCatFile->new($git_dir);
	my ($first, $last) = each_recent_blob($args, sub {
		my $mime = do_cat_mail($git, $_[0]) or return 0;

		my $t = eval { str2time($mime->header('Date')) };
		defined($t) or $t = 0;
		$mime->header_set('X-PI-Date', $t);
		push @messages, $mime;
		1;
	});
	$git = undef; # destroy pipes.

	my $th = PublicInbox::Thread->new(@messages);
	$th->thread;
	my $html = "<html><head><title>$title</title>" .
		'<link rel="alternate" title="Atom feed"' . "\nhref=\"" .
		$feed_opts->{atomurl} . "\"\ntype=\"application/atom+xml\"/>" .
		'</head><body>' . PRE_WRAP;

	# sort child messages in chronological order
	$th->order(sub {
		sort {
			$a->topmost->message->header('X-PI-Date') <=>
			$b->topmost->message->header('X-PI-Date')
		} @_;
	});

	# except we sort top-level messages reverse chronologically
	my $state = [ time, {}, $first, 0 ];
	for (sort { (eval { $b->message->header('X-PI-Date') } || 0) <=>
		    (eval { $a->message->header('X-PI-Date') } || 0)
		  } $th->rootset) {
		dump_msg($_, 0, \$html, $state);
	}
	Email::Address->purge_cache;

	my $footer = nav_footer($args->{cgi}, $last, $feed_opts, $state);
	if ($footer) {
		my $list_footer = $args->{footer};
		$footer .= "\n" . $list_footer if $list_footer;
		$footer = "<hr />" . PRE_WRAP . "$footer</pre>";
	}
	$html . "</pre>$footer</body></html>";
}

# private subs

sub nav_footer {
	my ($cgi, $last, $feed_opts, $state) = @_;
	$cgi or return '';
	my $old_r = $cgi->param('r');
	my $head = '    ';
	my $next = '    ';
	my $first = $state->[2];
	my $anchor = $state->[3];

	if ($last) {
		$next = qq!<a\nhref="?r=$last">next</a>!;
	}
	if ($old_r) {
		$head = $cgi->path_info;
		$head = qq!<a\nhref="$head">head</a>!;
	}
	my $atom = "<a\nhref=\"$feed_opts->{atomurl}\">atom</a>";
	my $permalink = "<a\nhref=\"?r=$first\">permalink</a>";
	"<a\nname=\"s$anchor\">page:</a> $next $head $atom $permalink";
}

sub each_recent_blob {
	my ($args, $cb) = @_;
	my $max = $args->{max} || MAX_PER_PAGE;
	my $hex = '[a-f0-9]';
	my $addmsg = qr!^:000000 100644 \S+ \S+ A\t(${hex}{2}/${hex}{38})$!;
	my $delmsg = qr!^:100644 000000 \S+ \S+ D\t(${hex}{2}/${hex}{38})$!;
	my $refhex = qr/${hex}{4,40}(?:~\d+)?/;
	my $cgi = $args->{cgi};

	# revision ranges may be specified
	my $range = 'HEAD';
	my $r = $cgi->param('r') if $cgi;
	if ($r && ($r =~ /\A(?:$refhex\.\.)?$refhex\z/o)) {
		$range = $r;
	}

	# get recent messages
	# we could use git log -z, but, we already know ssoma will not
	# leave us with filenames with spaces in them..
	my @cmd = ('git', "--git-dir=$args->{git_dir}",
			qw/log --no-notes --no-color --raw -r
			   --abbrev=16 --abbrev-commit/);
	push @cmd, $range;

	my $pid = open(my $log, '-|', @cmd) or
		die('open `'.join(' ', @cmd) . " pipe failed: $!\n");
	my %deleted; # only an optimization at this point
	my $last;
	my $nr = 0;
	my @commits = ();
	while (my $line = <$log>) {
		if ($line =~ /$addmsg/o) {
			my $add = $1;
			next if $deleted{$add};
			$nr += $cb->($add);
			if ($nr >= $max) {
				$last = 1;
				last;
			}
		} elsif ($line =~ /$delmsg/o) {
			$deleted{$1} = 1;
		} elsif ($line =~ /^commit (${hex}{7,40})/) {
			push @commits, $1;
		}
	}

	if ($last) {
		while (my $line = <$log>) {
			if ($line =~ /^commit (${hex}{7,40})/) {
				push @commits, $1;
				last;
			}
		}
	} else {
		push @commits, undef;
	}

	close $log; # we may EPIPE here
	# for pagination
	($commits[0], $commits[-1]);
}

# private functions below
sub get_feedopts {
	my ($args) = @_;
	my $pi_config = $args->{pi_config};
	my $listname = $args->{listname};
	my $cgi = $args->{cgi};
	my %rv;
	if (open my $fh, '<', "$args->{git_dir}/description") {
		chomp($rv{description} = <$fh>);
		close $fh;
	}

	if ($pi_config && defined $listname && length $listname) {
		foreach my $key (qw(address)) {
			$rv{$key} = $pi_config->get($listname, $key) || "";
		}
	}
	my $url_base;
	if ($cgi) {
		my $path_info = $cgi->path_info;
		my $base;
		if (ref($cgi) eq 'CGI') {
			$base = $cgi->url(-base);
		} else {
			$base = $cgi->base->as_string;
			$base =~ s!/\z!!;
		}
		$url_base = $path_info;
		if ($url_base =~ s!/(?:|index\.html)?\z!!) {
			$rv{atomurl} = "$base$url_base/atom.xml";
		} else {
			$url_base =~ s!/atom\.xml\z!!;
			$rv{atomurl} = $base . $path_info;
			$url_base = $base . $url_base; # XXX is this needed?
		}
	} else {
		$url_base = "http://example.com";
		$rv{atomurl} = "$url_base/atom.xml";
	}
	$rv{url} ||= "$url_base/";
	$rv{midurl} = "$url_base/m/";
	$rv{fullurl} = "$url_base/f/";

	\%rv;
}

sub mime_header {
	my ($mime, $name) = @_;
	PublicInbox::Hval->new_oneline($mime->header($name))->raw;
}

sub feed_date {
	my ($date) = @_;
	my @t = eval { strptime($date) };

	scalar(@t) ? POSIX::strftime(DATEFMT, @t) : 0;
}

# returns 0 (skipped) or 1 (added)
sub add_to_feed {
	my ($feed_opts, $feed, $add, $git) = @_;

	my $mime = do_cat_mail($git, $add) or return 0;
	my $midurl = $feed_opts->{midurl} || 'http://example.com/m/';
	my $fullurl = $feed_opts->{fullurl} || 'http://example.com/f/';

	my $mid = $mime->header_obj->header_raw('Message-ID');
	defined $mid or return 0;
	$mid = PublicInbox::Hval->new_msgid($mid);
	my $href = $mid->as_href . '.html';
	my $content = PublicInbox::View->feed_entry($mime, $fullurl . $href);
	defined($content) or return 0;

	my $subject = mime_header($mime, 'Subject') or return 0;

	my $from = mime_header($mime, 'From') or return 0;
	my @from = Email::Address->parse($from);
	my $name = $from[0]->name;
	defined $name or $name = "";
	my $email = $from[0]->address;
	defined $email or $email = "";

	my $date = $mime->header('Date');
	$date = PublicInbox::Hval->new_oneline($date);
	$date = feed_date($date->raw) or return 0;
	$add =~ tr!/!!d;
	my $h = '[a-f0-9]';
	my (@uuid5) = ($add =~ m!\A($h{8})($h{4})($h{4})($h{4})($h{12})!o);

	$feed->add_entry(
		author => { name => $name, email => $email },
		title => $subject,
		updated => $date,
		content => { type => 'xhtml', content => $content },
		link => $midurl . $href,
		id => 'urn:uuid:' . join('-', @uuid5),
	);
	1;
}

sub dump_msg {
	my ($self, $level, $html, $state) = @_;
	my $mime = $self->message;
	if ($mime) {
		$$html .= PublicInbox::View->index_entry($mime, $level, $state);
	}
	dump_msg($self->child, $level+1, $html, $state) if $self->child;
	dump_msg($self->next, $level, $html, $state) if $self->next;
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
