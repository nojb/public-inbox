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

	my @entries;

	# get recent messages
	# we could use git log -z, but, we already know ssoma will not
	# leave us with filenames with spaces in them..
	my $cmd = "git log --no-color --raw -r --no-abbrev HEAD |";
	my $pid = open my $log, $cmd or die "open `$cmd' pipe failed: $!\n";
	my %deleted;
	my $nr = 0;
	foreach my $line (<$log>) {
		if ($line =~ /^:000000 100644 0{40} ([a-f0-9]{40})/) {
			my $add = $1;
			next if $deleted{$add};
			$nr += add_to_feed($feed_opts, $feed, $add, $top);
			last if $nr >= $max;
		} elsif ($line =~ /^:100644 000000 ([a-f0-9]{40}) 0{40}/) {
			$deleted{$1} = 1;
		}
	}

	close $log;

	$feed->as_string;
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
			$rv{$key} = $pi_config->get($listname, $key);
		}
	}
	if ($cgi) {
		my $cgi_url = $cgi->self_url;
		my $url_base = $cgi_url;
		$url_base =~ s!/?(?:index|all)\.atom\.xml\z!!;
		$rv{url} ||= "$url_base/";
		$rv{midurl} = "$url_base/mid/";
		$rv{fullurl} = "$url_base/full/";
		$rv{atomurl} = $cgi_url;
	}

	\%rv;
}

sub utf8_header {
	my ($mime, $name) = @_;
	encode('utf8', decode('MIME-Header', $mime->header($name)));
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

	my $midurl = $feed_opts->{midurl} || 'http://example.com/mid/';
	my $fullurl = $feed_opts->{fullurl} || 'http://example.com/full/';

	my $content = PublicInbox::View->as_feed_entry($mime, $fullurl);
	defined($content) or return 0;

	my $mid = utf8_header($mime, "Message-ID") or return 0;
	$mid =~ s/\A<//;
	$mid =~ s/>\z//;

	my $subject = utf8_header($mime, "Subject") || "";
	defined($subject) && length($subject) or return 0;

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

1;
