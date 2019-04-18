# Copyright (C) 2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Provide an HTTP-accessible listing of inboxes.
# Used by PublicInbox::WWW
package PublicInbox::WwwListing;
use strict;
use warnings;
use PublicInbox::Hval qw(ascii_html);
use PublicInbox::Linkify;
use PublicInbox::View;

sub list_all ($$) {
	my ($self, undef) = @_;
	my @list;
	$self->{pi_config}->each_inbox(sub {
		my ($ibx) = @_;
		push @list, $ibx unless $ibx->{-hide}->{www};
	});
	\@list;
}

sub list_match_domain ($$) {
	my ($self, $env) = @_;
	my @list;
	my $host = $env->{HTTP_HOST} // $env->{SERVER_NAME};
	$host =~ s/:\d+\z//;
	my $re = qr!\A(?:https?:)?//\Q$host\E(?::\d+)?/!i;
	$self->{pi_config}->each_inbox(sub {
		my ($ibx) = @_;
		push @list, $ibx if !$ibx->{-hide}->{www} && $ibx->{url} =~ $re;
	});
	\@list;
}

sub list_404 ($$) { [] }

# TODO: +cgit
my %VALID = (
	all => *list_all,
	'match=domain' => *list_match_domain,
	404 => *list_404,
);

sub new {
	my ($class, $www) = @_;
	my $k = 'publicinbox.wwwListing';
	my $pi_config = $www->{pi_config};
	my $v = $pi_config->{lc($k)} // 404;
	bless {
		pi_config => $pi_config,
		style => $www->style("\0"),
		list_cb => $VALID{$v} || do {
			warn <<"";
`$v' is not a valid value for `$k'
$k be one of `all', `match=domain', or `404'

			*list_404;
		},
	}, $class;
}

sub ibx_entry {
	my ($mtime, $ibx, $env) = @_;
	my $ts = PublicInbox::View::fmt_ts($mtime);
	my $url = PublicInbox::Hval::prurl($env, $ibx->{url});
	my $tmp = <<"";
* $ts - $url
  ${\$ibx->description}

	if (defined(my $info_url = $ibx->{info_url})) {
		$tmp .= "\n$info_url";
	}
	$tmp;
}

# not really a stand-alone PSGI app, but maybe it could be...
sub call {
	my ($self, $env) = @_;
	my $h = [ 'Content-Type', 'text/html; charset=UTF-8' ];
	my $list = $self->{list_cb}->($self, $env);
	my $code = 404;
	my $title = 'public-inbox';
	my $out = '';
	if (@$list) {
		# Swartzian transform since ->modified is expensive
		@$list = sort {
			$b->[0] <=> $a->[0]
		} map { [ $_->modified, $_ ] } @$list;

		$code = 200;
		$title .= ' - listing';
		my $tmp = join("\n", map { ibx_entry(@$_, $env) } @$list);
		my $l = PublicInbox::Linkify->new;
		$l->linkify_1($tmp);
		$out = '<pre>'.$l->linkify_2(ascii_html($tmp)).'</pre><hr>';
	}
	$out = "<html><head><title>$title</title></head><body>" . $out;
	$out .= '<pre>'. PublicInbox::WwwStream::code_footer($env) .
		'</pre></body></html>';
	[ $code, $h, [ $out ] ]
}

1;
