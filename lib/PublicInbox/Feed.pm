# Copyright (C) 2013, Eric Wong <normalperson@yhbt.net> and all contributors
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
package PublicInbox::Feed;
use strict;
use warnings;
use Email::Address;
use Email::MIME;
use Date::Parse qw(strptime str2time);
use PublicInbox::Hval;
eval { require Git }; # this is GPLv2+, so we are OK to use it
use constant {
	DATEFMT => '%Y-%m-%dT%H:%M:%SZ',
	MAX_PER_PAGE => 25,
};

# FIXME: workaround https://rt.cpan.org/Public/Bug/Display.html?id=22817

# main function
sub generate {
	my ($class, $args) = @_;
	require XML::Atom::SimpleFeed;
	require PublicInbox::View;
	require POSIX;
	my $max = $args->{max} || MAX_PER_PAGE;
	my $top = $args->{top}; # bool

	local $ENV{GIT_DIR} = $args->{git_dir};
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

	my $title = $feed_opts->{description} || '';
	$title = PublicInbox::Hval->new_oneline($title)->as_html;

	my @messages;
	my $git = try_git_pm($args->{git_dir});
	my ($first, $last) = each_recent_blob($args, sub {
		my $mime = do_cat_mail($git, $_[0])
			or return 0;
		if ($top && ($mime->header('In-Reply-To') ||
		             $mime->header('References'))) {
			return 0;
		}
		$mime->body_set(''); # save some memory

		my $t = eval { str2time($mime->header('Date')) };
		defined($t) or $t = 0;
		$mime->header_set('X-PI-Date', $t);
		push @messages, $mime;
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
	my $hex = '[a-f0-9]';
	my $addmsg = qr!^:000000 100644 \S+ \S+ A\t(${hex}{2}/${hex}{38})$!;
	my $delmsg = qr!^:100644 000000 \S+ \S+ D\t(${hex}{2}/${hex}{38})$!;
	my $refhex = qr/${hex}{4,40}(?:~\d+)?/;
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
	my @cmd = qw/git log --no-notes --no-color --raw -r/;
	push @cmd, '--reverse' if $reverse;
	push @cmd, $range;
	my $first;

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
		} elsif ($line =~ /^commit (${hex}{40})/) {
			push @commits, $1;
		}
	}

	if ($last) {
		while (my $line = <$log>) {
			if ($line =~ /^commit (${hex}{40})/) {
				push @commits, $1;
				last;
			}
		}
	} elsif ($reverse) {
		unshift @commits, undef
	} else {
		push @commits, undef;
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
	my ($feed_opts, $feed, $add, $top, $git) = @_;

	my $mime = do_cat_mail($git, $add) or return 0;
	if ($top && $mime->header('In-Reply-To')) {
		return 0;
	}

	my $midurl = $feed_opts->{midurl} || 'http://example.com/m/';
	my $fullurl = $feed_opts->{fullurl} || 'http://example.com/f/';

	my $mid = $mime->header_obj->header_raw('Message-ID');
	defined $mid or return 0;
	$mid = PublicInbox::Hval->new_msgid($mid);
	my $href = $mid->as_href;
	my $content = PublicInbox::View->as_feed_entry($mime,
							"$fullurl$href.html");
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
		content => { type => "html", content => $content },
		link => $midurl . $href,
		id => 'urn:uuid:' . join('-', @uuid5),
	);
	1;
}

sub dump_html_line {
	my ($self, $level, $args) = @_; # args => [ $html, $midurl ]
	if ($self->message) {
		$args->[0] .= (' ' x $level);
		my $mime = $self->message;
		my $subj = $mime->header('Subject');
		my $mid = $mime->header_obj->header_raw('Message-ID');
		$mid = PublicInbox::Hval->new_msgid($mid);
		my $url = $args->[1] . $mid->as_href;
		my $from = mime_header($mime, 'From');

		my @from = Email::Address->parse($from);
		$from = $from[0]->name;
		(defined($from) && length($from)) or $from = $from[0]->address;

		$from = PublicInbox::Hval->new_oneline($from)->as_html;
		$subj = PublicInbox::Hval->new_oneline($subj)->as_html;
		$args->[0] .= "<a href=\"$url.html\">$subj</a> $from\n";
	}
	dump_html_line($self->child, $level+1, $args) if $self->child;
	dump_html_line($self->next, $level, $args) if $self->next;
}

sub try_git_pm {
	my ($dir) = @_;
	eval { Git->repository(Directory => $dir) };
};

sub do_cat_mail {
	my ($git, $path) = @_;
	my $str;
	if ($git) {
		open my $fh, '>', \$str or
				die "failed to setup string handle: $!\n";
		binmode $fh;
		my $err = '';
		my $bytes;
		{
			local $SIG{__WARN__} = sub { $err .= $_[0] };
			$bytes = $git->cat_blob("HEAD:$path", $fh);
		}
		close $fh or die "failed to close string handle: $!\n";

		if ($bytes < 0 && $err &&
				$err !~ /doesn't exist in the repository/) {
			warn $err;
		}
		return if $bytes <= 0;
	} else {
		$str = `git cat-file blob HEAD:$path`;
		return if $? != 0 || length($str) == 0;
	}
	Email::MIME->new($str);
}

1;
