# Copyright (C) 2016-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Plack app redirector for mapping /$NEWSGROUP requests to
# the appropriate /$INBOX in PublicInbox::WWW because some
# auto-linkifiers cannot handle nntp:// redirects properly.
# This is also used directly by PublicInbox::WWW
package PublicInbox::NewsWWW;
use strict;
use warnings;
use PublicInbox::Config;
use PublicInbox::MID qw(mid_escape);

sub new {
	my ($class, $pi_config) = @_;
	$pi_config ||= PublicInbox::Config->new;
	bless { pi_config => $pi_config }, $class;
}

sub call {
	my ($self, $env) = @_;
	my $path = $env->{PATH_INFO};
	$path =~ s!\A/+!!;
	$path =~ s!/+\z!!;

	# some links may have the article number in them:
	# /inbox.foo.bar/123456
	my ($ng, $article) = split(m!/+!, $path, 2);
	if (my $inbox = $self->{pi_config}->lookup_newsgroup($ng)) {
		my $url = PublicInbox::Hval::prurl($env, $inbox->{url});
		my $code = 301;
		if (defined $article && $article =~ /\A\d+\z/) {
			my $mid = eval { $inbox->mm->mid_for($article) };
			if (defined $mid) {
				# article IDs are not stable across clones,
				# do not encourage caching/bookmarking them
				$code = 302;
				$url .= mid_escape($mid) . '/';
			}
		}

		my $h = [ Location => $url, 'Content-Type' => 'text/plain' ];

		return [ $code, $h, [ "Redirecting to $url\n" ] ]
	}
	[ 404, [ 'Content-Type' => 'text/plain' ], [ "404 Not Found\n" ] ];
}

1;
