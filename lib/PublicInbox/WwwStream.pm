# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# HTML body stream for which yields getline+close methods
package PublicInbox::WwwStream;
use strict;
use warnings;
use PublicInbox::Hval qw(ascii_html);
use URI;
our $TOR_URL = 'https://www.torproject.org/';
our $TOR2WEB_URL = 'https://www.tor2web.org/';
our $CODE_URL = 'https://public-inbox.org/';
our $PROJECT = 'public-inbox';

sub close {}

sub new {
	my ($class, $ctx, $cb) = @_;
	bless { nr => 0, cb => $cb || *close, ctx => $ctx }, $class;
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
	my $help = $upfx.'_/text/help';
	my $atom = $ctx->{-atom} || $upfx.'new.atom';
	my $tip = $ctx->{-html_tip} || '';
	my $top = "<b>$desc</b>";
	my $links = "<a\nhref=\"$help\">help</a> / ".
			"<a\nhref=\"$atom\">Atom feed</a>";
	if ($obj->search) {
		my $q_val = $ctx->{-q_value_html};
		if (defined $q_val && $q_val ne '') {
			$q_val = qq(\nvalue="$q_val");
		} else {
			$q_val = '';
		}
		# XXX gross, for SearchView.pm
		my $extra = $ctx->{-extra_form_html} || '';
		my $action = $upfx eq '' ? './' : $upfx;
		$top = qq{<form\naction="$action"><pre>$top} .
			  qq{\n<input\nname=q\ntype=text$q_val />} .
			  $extra .
			  qq{<input\ntype=submit\nvalue=search />} .
			  ' ' . $links .
			  q{</pre></form>}
	} else {
		$top = '<pre>' . $top . "\n" . $links . '</pre>';
	}
	"<html><head><title>$title</title>" .
		"<link\nrel=alternate\ntitle=\"Atom feed\"\n".
		"href=\"$atom\"\ntype=\"application/atom+xml\"/>" .
		PublicInbox::Hval::STYLE .
		"</head><body>". $top . $tip;
}

sub _html_end {
	my ($self) = @_;
	my $urls = 'Archives are clonable:';
	my $ctx = $self->{ctx};
	my $obj = $ctx->{-inbox};
	my $desc = ascii_html($obj->description);

	my $http = $obj->base_url($ctx->{env});
	chop $http;
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

	my @nntp = map { qq(<a\nhref="$_">$_</a>) } @{$obj->nntp_url};
	if (@nntp) {
		$urls .= "\n\n";
		$urls .= @nntp == 1 ? 'Newsgroup' : 'Newsgroups are';
		$urls .= ' available over NNTP:';
		$urls .= "\n\t" . join("\n\t", @nntp) . "\n";
	}
	if ($urls =~ m!\b[^:]+://\w+\.onion/!) {
		$urls .= "\n note: .onion URLs require Tor: ";
		$urls .= qq[<a\nhref="$TOR_URL">$TOR_URL</a>];
		if ($TOR2WEB_URL) {
			$urls .= "\n       or Tor2web: ";
			$urls .= qq[<a\nhref="$TOR2WEB_URL">$TOR2WEB_URL</a>];
		}
	}
	my $url = PublicInbox::Hval::prurl($ctx->{env}, $CODE_URL);
	'<hr><pre>'.join("\n\n",
		$desc,
		$urls,
		'AGPL code for this site: '.
		qq(git clone <a\nhref="$url">$url</a> $PROJECT)
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

1;
