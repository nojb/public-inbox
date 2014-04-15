# Copyright (C) 2013, Eric Wong <normalperson@yhbt.net> and all contributors
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
package PublicInbox::Feed;
use strict;
use warnings;
use XML::Atom::SimpleFeed;
use Email::MIME;
use Email::Address;
use URI::Escape qw/uri_escape/;
use Encode qw/encode decode/;
use Encode::MIME::Header;
use CGI qw(escapeHTML);
use POSIX qw(strftime);
use Date::Parse qw(strptime);
use constant DATEFMT => '%Y-%m-%dT%H:%M:%SZ';
use PublicInbox::View;
use Mail::Thread;

# main function
sub generate {
	my ($class, $args) = @_;
	my $max = $args->{max} || 25;
	my $top = $args->{top}; # bool

	local $ENV{GIT_DIR} = $args->{git_dir};
	my $feed_opts = get_feedopts($args);

	my $feed = XML::Atom::SimpleFeed->new(
		title => $feed_opts->{description} || "unnamed feed",
		link => $feed_opts->{url} || "http://example.com/",
		link => {
			rel => 'self',
			href => $feed_opts->{atomurl} ||
				"http://example.com/atom",
		},
		id => $feed_opts->{address} || 'public-inbox@example.com',
		updated => strftime(DATEFMT, gmtime),
	);

	each_recent_blob($max, sub {
		my ($add) = @_;
		add_to_feed($feed_opts, $feed, $add, $top);
	});
	$feed->as_string;
}

sub generate_html_index {
	my ($class, $args) = @_;
	my $max = $args->{max} || 50;
	my $top = $args->{top}; # bool
	local $ENV{GIT_DIR} = $args->{git_dir};
	my $feed_opts = get_feedopts($args);
	my $title = escapeHTML($feed_opts->{description} || "");
	my @messages;
	each_recent_blob($max, sub {
		my $str = `git cat-file blob $_[0]`;
		return 0 if $? != 0;
		my $simple = Email::Simple->new($str);
		if ($top && ($simple->header("In-Reply-To") ||
		             $simple->header("References"))) {
			return 0;
		}
		$simple->body_set(""); # save some memory
		push @messages, $simple;
		1;
	});

	my $th = Mail::Thread->new(@messages);
	$th->thread;
	my @args = (
		"<html><head><title>$title</title>" .
		'<link rel=alternate title=Atom.feed href="' .
		$feed_opts->{atomurl} . '" type="application/atom+xml"/>' .
		'</head><body><pre>');
	push @args, $feed_opts->{midurl};
	dump_html_line($_, 0, \@args) for $th->rootset;
	$args[0] . '</pre></html>';
}

# private subs

sub each_recent_blob {
	my ($max, $cb) = @_;

	# get recent messages
	# we could use git log -z, but, we already know ssoma will not
	# leave us with filenames with spaces in them..
	my $cmd = "git log --no-notes --no-color --raw -r --no-abbrev HEAD |";
	my $pid = open my $log, $cmd or die "open `$cmd' pipe failed: $!\n";
	my %deleted;
	my $nr = 0;
	foreach my $line (<$log>) {
		if ($line =~ /^:000000 100644 0{40} ([a-f0-9]{40})/) {
			my $add = $1;
			next if $deleted{$add};
			$nr += $cb->($add);
			last if $nr >= $max;
		} elsif ($line =~ /^:100644 000000 ([a-f0-9]{40}) 0{40}/) {
			$deleted{$1} = 1;
		}
	}

	close $log;
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
		my $cgi_url = $cgi->url(-path=>1, -query=>1, -relative=>1);
		my $base = $cgi->url(-base);
		$url_base = $cgi_url;
		if ($url_base =~ s!/(?:|index\.html)?\z!!) {
			$rv{atomurl} = "$base$url_base/index.atom.xml";
		} else {
			$url_base =~ s!/?(?:index|all)\.atom\.xml\z!!;
			$rv{atomurl} = $base . $cgi_url;
			$url_base = $base . $url_base; # XXX is this needed?
		}
	} else {
		$url_base = "http://example.com";
		$rv{atomurl} = "$url_base/index.atom.xml";
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
	$val =~ tr/\t\r\n / /s;
	encode('utf8', decode('MIME-Header', $val));
}

sub feed_date {
	my ($date) = @_;
	my @t = eval { strptime($date) };

	scalar(@t) ? strftime(DATEFMT, @t) : 0;
}

# returns 0 (skipped) or 1 (added)
sub add_to_feed {
	my ($feed_opts, $feed, $add, $top) = @_;

	# we can use git cat-file --batch if performance becomes a
	# problem, but I doubt it...
	my $str = `git cat-file blob $add`;
	return 0 if $? != 0;
	my $mime = Email::MIME->new($str);

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
	$args->[0] .= (' ' x $level);
	if ($self->message) {
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
		$from = escapeHTML($from);
		$subj = escapeHTML($subj);
		$args->[0] .= "<a href=\"$url.html\">`-&gt; $subj</a> $from\n";
	} else {
		$args->[0] .= "[ Message not available ]\n";
	}
	dump_html_line($self->child, $level+1, $args) if $self->child;
	dump_html_line($self->next, $level, $args) if $self->next;
}

1;
