# Copyright (C) 2013, Eric Wong <normalperson@yhbt.net> and all contributors
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
package PublicInbox::Feed;
use strict;
use warnings;
use Email::Address;
use URI::Escape qw/uri_escape/;
use Encode qw/find_encoding/;
use Encode::MIME::Header;
use CGI qw(escapeHTML);
use Date::Parse qw(strptime str2time);
eval { require Git }; # this is GPLv2+, so we are OK to use it
use constant {
	DATEFMT => '%Y-%m-%dT%H:%M:%SZ',
	MAX_PER_PAGE => 25,
};
my $enc_utf8 = find_encoding('utf8');
my $enc_ascii = find_encoding('us-ascii');
my $enc_mime = find_encoding('MIME-Header');

# FIXME: workaround https://rt.cpan.org/Public/Bug/Display.html?id=22817

# main function
sub generate {
	my ($class, $args) = @_;
	require XML::Atom::SimpleFeed;
	require PublicInbox::View;
	require Email::MIME;
	require POSIX;
	my $max = $args->{max} || MAX_PER_PAGE;
	my $top = $args->{top}; # bool

	local $ENV{GIT_DIR} = $args->{git_dir};
	my $feed_opts = get_feedopts($args);

	my $feed = XML::Atom::SimpleFeed->new(
		title => $feed_opts->{description} || "unnamed feed",
		link => $feed_opts->{url} || "http://example.com/",
		link => {
			rel => 'self',
			href => $feed_opts->{atomurl} ||
				"http://example.com/atom.xml",
		},
		id => $feed_opts->{address} || 'public-inbox@example.com',
		updated => POSIX::strftime(DATEFMT, gmtime),
	);

	my $git = try_git_pm($args->{git_dir});
	each_recent_blob($args, sub {
		my ($add) = @_;
		add_to_feed($feed_opts, $feed, $add, $top, $git);
	});
	$feed->as_string;
}

sub generate_html_index {
	my ($class, $args) = @_;
	require Mail::Thread;

	my $max = $args->{max} || MAX_PER_PAGE;
	my $top = $args->{top}; # bool
	local $ENV{GIT_DIR} = $args->{git_dir};
	my $feed_opts = get_feedopts($args);
	my $title = xs_html($feed_opts->{description} || "");
	my @messages;
	my $git = try_git_pm($args->{git_dir});
	my ($first, $last) = each_recent_blob($args, sub {
		my $simple = do_cat_mail($git, 'Email::Simple', $_[0])
			or return 0;
		if ($top && ($simple->header("In-Reply-To") ||
		             $simple->header("References"))) {
			return 0;
		}
		$simple->body_set(""); # save some memory

		my $t = eval { str2time($simple->header('Date')) };
		defined($t) or $t = 0;
		$simple->header_set('X-PI-Date', $t);
		push @messages, $simple;
		1;
	});

	my $th = Mail::Thread->new(@messages);
	$th->thread;
	my @out = (
		"<html><head><title>$title</title>" .
		'<link rel=alternate title=Atom.feed href="' .
		$feed_opts->{atomurl} . '" type="application/atom+xml"/>' .
		'</head><body><pre>');
	push @out, $feed_opts->{midurl};

	# sort by date, most recent at top
	$th->order(sub {
		sort {
			$b->topmost->message->header('X-PI-Date') <=>
			$a->topmost->message->header('X-PI-Date')
		} @_;
	});
	dump_html_line($_, 0, \@out) for $th->rootset;

	my $footer = nav_footer($args->{cgi}, $first, $last);
	$footer = "<hr /><pre>$footer</pre>" if $footer;
	$out[0] . "</pre>$footer</html>";
}

# private subs

sub nav_footer {
	my ($cgi, $first, $last) = @_;
	$cgi or return '';
	my $old_r = $cgi->param('r');
	my $prev = '    ';
	my $next = '    ';
	my %opts = (-path => 1, -query => 1, -relative => 1);

	if ($last) {
		$cgi->param('r', $last);
		$next = $cgi->url(%opts);
		$next = qq!<a href="$next">next</a>!;
	}
	if ($first && $old_r) {
		$cgi->param('r', "$first..");
		$prev = $cgi->url(%opts);
		$prev = qq!<a href="$prev">prev</a>!;
	}
	"$prev $next";
}

sub each_recent_blob {
	my ($args, $cb) = @_;
	my $max = $args->{max} || MAX_PER_PAGE;
	my $refhex = qr/[a-f0-9]{4,40}(?:~\d+)?/;
	my $cgi = $args->{cgi};

	# revision ranges may be specified
	my $reverse;
	my $range = 'HEAD';
	my $r = $cgi->param('r') if $cgi;
	if ($r) {
		if ($r =~ /\A(?:$refhex\.\.)?$refhex\z/o) {
			$range = $r;
		} elsif ($r =~ /\A(?:$refhex\.\.)\z/o) {
			$reverse = 1;
			$range = $r;
		}
	}

	# get recent messages
	# we could use git log -z, but, we already know ssoma will not
	# leave us with filenames with spaces in them..
	my @cmd = qw/git log --no-notes --no-color --raw -r --no-abbrev/;
	push @cmd, '--reverse' if $reverse;
	push @cmd, $range;
	my $first;

	my $pid = open(my $log, '-|', @cmd) or
		die('open `'.join(' ', @cmd) . " pipe failed: $!\n");
	my %deleted;
	my $last;
	my $nr = 0;
	my @commits = ();
	while (my $line = <$log>) {
		if ($line =~ /^:000000 100644 0{40} ([a-f0-9]{40})/) {
			my $add = $1;
			next if $deleted{$add};
			$nr += $cb->($add);
			if ($nr >= $max) {
				$last = 1;
				last;
			}
		} elsif ($line =~ /^:100644 000000 ([a-f0-9]{40}) 0{40}/) {
			$deleted{$1} = 1;
		} elsif ($line =~ /^commit ([a-f0-9]{40})/) {
			push @commits, $1;
		}
	}

	if ($last) {
		while (my $line = <$log>) {
			if ($line =~ /^commit ([a-f0-9]{40})/) {
				push @commits, $1;
				last;
			}
		}
	}

	close $log; # we may EPIPE here
	# for pagination
	$reverse ? ($commits[-1],$commits[0]) : ($commits[0],$commits[-1]);
}

# private functions below
sub get_feedopts {
	my ($args) = @_;
	my $pi_config = $args->{pi_config};
	my $listname = $args->{listname};
	my $cgi = $args->{cgi};
	my %rv;

	if ($pi_config && defined $listname && length $listname) {
		foreach my $key (qw(description address)) {
			$rv{$key} = $pi_config->get($listname, $key) || "";
		}
	}
	my $url_base;
	if ($cgi) {
		my $cgi_url = $cgi->url(-path=>1, -relative=>1);
		my $base = $cgi->url(-base);
		$url_base = $cgi_url;
		if ($url_base =~ s!/(?:|index\.html)?\z!!) {
			$rv{atomurl} = "$base$url_base/atom.xml";
		} else {
			$url_base =~ s!/atom\.xml\z!!;
			$rv{atomurl} = $base . $cgi_url;
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

sub utf8_header {
	my ($simple, $name) = @_;
	my $val = $simple->header($name);
	return "" unless defined $val;
	$val =~ tr/\t\n / /s;
	$val =~ tr/\r//d;
	$enc_utf8->encode($enc_mime->decode($val));
}

sub feed_date {
	my ($date) = @_;
	my @t = eval { strptime($date) };

	scalar(@t) ? POSIX::strftime(DATEFMT, @t) : 0;
}

# returns 0 (skipped) or 1 (added)
sub add_to_feed {
	my ($feed_opts, $feed, $add, $top, $git) = @_;

	my $mime = do_cat_mail($git, 'Email::MIME', $add) or return 0;
	if ($top && $mime->header("In-Reply-To")) {
		return 0;
	}

	my $midurl = $feed_opts->{midurl} || 'http://example.com/m/';
	my $fullurl = $feed_opts->{fullurl} || 'http://example.com/f/';

	my $content = PublicInbox::View->as_feed_entry($mime, $fullurl);
	defined($content) or return 0;

	my $mid = utf8_header($mime, "Message-ID") or return 0;
	$mid =~ s/\A<//; $mid =~ s/>\z//;

	my $subject = utf8_header($mime, "Subject") || "";
	length($subject) or return 0;

	my $from = utf8_header($mime, "From") or return 0;

	my @from = Email::Address->parse($from);
	my $name = $from[0]->name;
	defined $name or $name = "";
	my $email = $from[0]->address;
	defined $email or $email = "";

	my $url = $midurl . uri_escape($mid);
	my $date = utf8_header($mime, "Date");
	$date or return 0;
	$date = feed_date($date) or return 0;
	$feed->add_entry(
		author => { name => $name, email => $email },
		title => $subject,
		updated => $date,
		content => { type => "html", content => $content },
		link => $url,
		id => $add,
	);
	1;
}

sub dump_html_line {
	my ($self, $level, $args) = @_; # args => [ $html, $midurl ]
	if ($self->message) {
		$args->[0] .= (' ' x $level);
		my $simple = $self->message;
		my $subj = utf8_header($simple, "Subject");
		my $mid = utf8_header($simple, "Message-ID");
		$mid =~ s/\A<//;
		$mid =~ s/>\z//;
		my $url = $args->[1] . uri_escape($mid);
		my $from = utf8_header($simple, "From");
		my @from = Email::Address->parse($from);
		$from = $from[0]->name;
		(defined($from) && length($from)) or $from = $from[0]->address;
		$from = xs_html($from);
		$subj = xs_html($subj);
		$args->[0] .= "<a href=\"$url.html\">$subj</a> $from\n";
	}
	dump_html_line($self->child, $level+1, $args) if $self->child;
	dump_html_line($self->next, $level, $args) if $self->next;
}

sub xs_html {
	$enc_ascii->encode(escapeHTML($enc_utf8->decode($_[0])),
			Encode::HTMLCREF);
}

sub try_git_pm {
	my ($dir) = @_;
	eval { Git->repository(Directory => $dir) };
};

sub do_cat_mail {
	my ($git, $class, $sha1) = @_;
	my $str;
	if ($git) {
		open my $fh, '>', \$str or
				die "failed to setup string handle: $!\n";
		binmode $fh;
		my $bytes = $git->cat_blob($sha1, $fh);
		close $fh or die "failed to close string handle: $!\n";
		return if $bytes <= 0;
	} else {
		$str = `git cat-file blob $sha1`;
		return if $? != 0 || length($str) == 0;
	}
	$class->new($str);
}

1;
