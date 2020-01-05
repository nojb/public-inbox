# Copyright (C) 2016-2019 all contributors <meta@public-inbox.org>
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
use PublicInbox::Hval qw(prurl);

sub new {
	my ($class, $pi_config) = @_;
	$pi_config ||= PublicInbox::Config->new;
	bless { pi_config => $pi_config }, $class;
}

sub redirect ($$) {
	my ($code, $url) = @_;
	[ $code,
	  [ Location => $url, 'Content-Type' => 'text/plain' ],
	  [ "Redirecting to $url\n" ] ]
}

sub try_inbox {
	my ($ibx, $arg) = @_;
	return if scalar(@$arg) > 1;

	# do not pass $env since HTTP_HOST may differ
	my $url = $ibx->base_url or return;

	my ($mid) = @$arg;
	eval { $ibx->mm->num_for($mid) } or return;

	# 302 since the same message may show up on
	# multiple inboxes and inboxes can be added/reordered
	$arg->[1] = redirect(302, $url .= mid_escape($mid) . '/');
}

sub call {
	my ($self, $env) = @_;

	# some links may have the article number in them:
	# /inbox.foo.bar/123456
	my (undef, @parts) = split(m!/!, $env->{PATH_INFO});
	my ($ng, $article) = @parts;
	my $pi_config = $self->{pi_config};
	if (my $ibx = $pi_config->lookup_newsgroup($ng)) {
		my $url = prurl($env, $ibx->{url});
		my $code = 301;
		if (defined $article && $article =~ /\A[0-9]+\z/) {
			my $mid = eval { $ibx->mm->mid_for($article) };
			if (defined $mid) {
				# article IDs are not stable across clones,
				# do not encourage caching/bookmarking them
				$code = 302;
				$url .= mid_escape($mid) . '/';
			}
		}
		return redirect($code, $url);
	}

	my $res;
	my @try = (join('/', @parts));

	# trailing slash is in the rest of our WWW, so maybe some users
	# will assume it:
	if ($parts[-1] eq '') {
		pop @parts;
		push @try, join('/', @parts);
	}

	foreach my $mid (@try) {
		my $arg = [ $mid ];
		$pi_config->each_inbox(\&try_inbox, $arg);
		defined($res = $arg->[1]) and last;
	}
	$res || [ 404, [qw(Content-Type text/plain)], ["404 Not Found\n"] ];
}

1;
