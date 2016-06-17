# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# HTML body stream for which yields getline+close methods
package PublicInbox::WwwStream;
use strict;
use warnings;
use PublicInbox::Hval qw(ascii_html);
use URI;
use constant PI_URL => 'https://public-inbox.org/README.html';

sub new {
	my ($class, $ctx, $cb) = @_;
	bless { nr => 0, cb => $cb, ctx => $ctx }, $class;
}

sub _html_top ($) {
	my ($self) = @_;
	my $ctx = $self->{ctx};
	my $obj = $ctx->{-inbox};
	my $desc = ascii_html($obj->description);
	my $title = $ctx->{-title_html} || $desc;
	my $upfx = $ctx->{-upfx} || '';
	my $atom = $ctx->{-atom} || $upfx.'new.atom';
	my $top = "<b>$desc</b> (<a\nhref=\"$atom\">Atom feed</a>)";
	if ($obj->search) {
		$top = qq{<form\naction="$upfx"><pre>$top} .
			  qq{ <input\nname=q\ntype=text />} .
			  qq{<input\ntype=submit\nvalue=search />} .
			  q{</pre></form>}
	} else {
		$top = '<pre>' . $top . '</pre>';
	}
	"<html><head><title>$title</title>" .
		"<link\nrel=alternate\ntitle=\"Atom feed\"\n".
		"href=\"$atom\"\ntype=\"application/atom+xml\"/>" .
		PublicInbox::Hval::STYLE .
		"</head><body>$top";
}

sub _html_end {
	my ($self) = @_;
	my $urls = 'Archives are clone-able:';
	my $ctx = $self->{ctx};
	my $obj = $ctx->{-inbox};
	my $desc = ascii_html($obj->description);
	my @urls = @{$obj->cloneurl};
	my %seen = map { $_ => 1 } @urls;

	# FIXME: cleanup
	my $env = $ctx->{env};
	my $scheme = $env->{'psgi.url_scheme'};
	my $host_port = $env->{HTTP_HOST} ||
			"$env->{SERVER_NAME}:$env->{SERVER_PORT}";
	my $http = "$scheme://$host_port".($env->{SCRIPT_NAME} || '/');
	$http = URI->new($http . $obj->{name})->canonical->as_string;
	$seen{$http} or unshift @urls, $http;
	if (scalar(@urls) == 1) {
		$urls .= " git clone --mirror $urls[0]";
	} else {
		$urls .= "\n" .
			join("\n", map { "\tgit clone --mirror $_" } @urls);
	}
	my $url = PublicInbox::Hval::prurl($ctx->{env}, PI_URL);
	'<pre>'.join("\n",
		'- ' . $desc,
		$urls,
		'served with software from public-inbox: '
			."<a\nhref=\"$url\">$url</a>",
	).'</pre></body></html>';
}

sub getline {
	my ($self) = @_;
	my $nr = $self->{nr}++;

	return _html_top($self) if $nr == 0;

	if (my $mid = $self->{cb}) { # middle
		$mid = $mid->($nr, $self->{ctx}) and return $mid;
	}

	delete $self->{cb} ? _html_end($self) : undef;
}

sub close {}

1;
