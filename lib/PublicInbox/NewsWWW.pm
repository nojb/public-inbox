# Copyright (C) 2016 all contributors <meta@public-inbox.org>
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
use URI::Escape qw(uri_escape_utf8);

sub new {
	my ($class, $pi_config) = @_;
	$pi_config ||= PublicInbox::Config->new;
	bless { pi_config => $pi_config }, $class;
}

sub call {
	my ($self, $env) = @_;
	my $ng_map = $self->newsgroup_map;
	my $path = $env->{PATH_INFO};
	$path =~ s!\A/+!!;
	$path =~ s!/+\z!!;

	# some links may have the article number in them:
	# /inbox.foo.bar/123456
	my ($ng, $article) = split(m!/+!, $path, 2);
	if (my $info = $ng_map->{$ng}) {
		my $url = PublicInbox::Hval::prurl($env, $info->{url});
		my $code = 301;
		my $h = [ Location => $url, 'Content-Type' => 'text/plain' ];
		if (defined $article && $article =~ /\A\d+\z/) {
			my $mid = eval { ng_mid_for($ng, $info, $article) };
			if (defined $mid) {
				# article IDs are not stable across clones,
				# do not encourage caching/bookmarking them
				$code = 302;
				$url .= uri_escape_utf8($mid) . '/';
			}
		}

		return [ $code, $h, [ "Redirecting to $url\n" ] ]
	}
	[ 404, [ 'Content-Type' => 'text/plain' ], [] ];
}

sub ng_mid_for {
	my ($ng, $info, $article) = @_;
	# may fail due to lack of Danga::Socket
	# for defer_weaken:
	require PublicInbox::NewsGroup;
	$ng = $info->{ng} ||=
		PublicInbox::NewsGroup->new($ng, $info->{git_dir}, '');
	$ng->mm->mid_for($article);
}

sub newsgroup_map {
	my ($self) = @_;
	my $rv;
	$rv = $self->{ng_map} and return $rv;
	my $pi_config = $self->{pi_config};
	my %ng_map;
	foreach my $k (keys %$pi_config) {
		$k =~ /\Apublicinbox\.([^\.]+)\.mainrepo\z/ or next;
		my $inbox = $1;
		my $git_dir = $pi_config->{"publicinbox.$inbox.mainrepo"};
		my $url = $pi_config->{"publicinbox.$inbox.url"};
		defined $url or next;
		my $ng = $pi_config->{"publicinbox.$inbox.newsgroup"};
		next if (!defined $ng) || ($ng eq ''); # disabled

		$url =~ m!/\z! or $url .= '/';
		$ng_map{$ng} = { url => $url, git_dir => $git_dir };
	}
	$self->{ng_map} = \%ng_map;
}

1;
