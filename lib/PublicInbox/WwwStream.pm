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

sub response {
	my ($class, $ctx, $code, $cb) = @_;
	[ $code, [ 'Content-Type', 'text/html; charset=UTF-8' ],
	  $class->new($ctx, $cb) ]
}

sub _html_top ($) {
	my ($self) = @_;
	my $ctx = $self->{ctx};
	my $obj = $ctx->{-inbox};
	my $desc = ascii_html($obj->description);
	my $title = $ctx->{-title_html} || $desc;
	my $upfx = $ctx->{-upfx} || '';
	my $atom = $ctx->{-atom} || $upfx.'new.atom';
	my $tip = $ctx->{-html_tip} || '';
	my $top = "<b>$desc</b> (<a\nhref=\"$atom\">Atom feed</a>)";
	if ($obj->search) {
		my $q_val = $ctx->{-q_value_html};
		if (defined $q_val && $q_val ne '') {
			$q_val = qq(\nvalue="$q_val" );
		} else {
			$q_val = '';
		}
		# XXX gross, for SearchView.pm
		my $extra = $ctx->{-extra_form_html} || '';
		$top = qq{<form\naction="$upfx"><pre>$top} .
			  qq{ <input\nname=q\ntype=text$q_val/>} .
			  $extra .
			  qq{<input\ntype=submit\nvalue=search />} .
			  q{</pre></form>}
	} else {
		$top = '<pre>' . $top . '</pre>';
	}
	"<html><head><title>$title</title>" .
		"<link\nrel=alternate\ntitle=\"Atom feed\"\n".
		"href=\"$atom\"\ntype=\"application/atom+xml\"/>" .
		PublicInbox::Hval::STYLE .
		"</head><body>". $top . $tip;
}

sub _html_end {
	my ($self) = @_;
	my $urls = 'Archives are clone-able:';
	my $ctx = $self->{ctx};
	my $obj = $ctx->{-inbox};
	my $desc = ascii_html($obj->description);

	# FIXME: cleanup
	my $env = $ctx->{env};
	my $scheme = $env->{'psgi.url_scheme'};
	my $host_port = $env->{HTTP_HOST} ||
			"$env->{SERVER_NAME}:$env->{SERVER_PORT}";
	my $http = "$scheme://$host_port".($env->{SCRIPT_NAME} || '/');
	$http = URI->new($http . $obj->{name})->canonical->as_string;
	my %seen = ( $http => 1 );
	my @urls = ($http);
	foreach my $u (@{$obj->cloneurl}) {
		next if $seen{$u};
		$seen{$u} = 1;
		push @urls, $u =~ /\Ahttps?:/ ? qq(<a\nhref="$u">$u</a>) : $u;
	}
	if (scalar(@urls) == 1) {
		$urls .= " git clone --mirror $http";
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
