# Copyright (C) 2015 all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
package PublicInbox::ExtMsg;
use strict;
use warnings;
use URI::Escape qw(uri_escape_utf8);
use PublicInbox::Hval;
use PublicInbox::MID qw/mid_compress mid2path/;

sub ext_msg {
	my ($ctx) = @_;
	my $pi_config = $ctx->{pi_config};
	my $listname = $ctx->{listname};
	my $mid = $ctx->{mid};
	my $cmid = mid_compress($mid);

	eval { require PublicInbox::Search };
	my $have_xap = $@ ? 0 : 1;
	my @nox;

	foreach my $k (keys %$pi_config) {
		$k =~ /\Apublicinbox\.([A-Z0-9a-z-]+)\.url\z/ or next;
		my $list = $1;
		next if $list eq $listname;

		my $git_dir = $pi_config->{"publicinbox.$list.mainrepo"};
		defined $git_dir or next;

		my $url = $pi_config->{"publicinbox.$list.url"};
		defined $url or next;

		$url =~ s!/+\z!!;

		# try to find the URL with Xapian to avoid forking
		if ($have_xap) {
			my $doc_id = eval {
				my $s = PublicInbox::Search->new($git_dir);
				$s->find_unique_doc_id('mid', $cmid);
			};
			if ($@) {
				# xapian not configured for this repo
			} else {
				# maybe we found it!
				return r302($url, $cmid) if (defined $doc_id);

				# no point in trying the fork fallback if we
				# know Xapian is up-to-date but missing the
				# message in the current repo
				next;
			}
		}

		# queue up for forking after we've tried Xapian on all of them
		push @nox, { git_dir => $git_dir, url => $url };
	}

	# Xapian not installed or configured for some repos
	my $path = "HEAD:" . mid2path($cmid);

	foreach my $n (@nox) {
		my @cmd = ('git', "--git-dir=$n->{git_dir}", 'cat-file',
			   '-t', $path);
		my $pid = open my $fh, '-|';
		defined $pid or die "fork failed: $!\n";

		if ($pid == 0) {
			open STDERR, '>', '/dev/null'; # ignore errors
			exec @cmd or die "exec failed: $!\n";
		} else {
			my $type = eval { local $/; <$fh> };
			close $fh;
			if ($? == 0 && $type eq "blob\n") {
				return r302($n->{url}, $cmid);
			}
		}
	}

	# Fall back to external repos

	[404, ['Content-Type'=>'text/plain'], ['Not found']];
}

# Redirect to another public-inbox which is mapped by $pi_config
sub r302 {
	my ($url, $mid) = @_;
	$url .= '/' . uri_escape_utf8($mid) . '/';
	[ 302,
	  [ 'Location' => $url, 'Content-Type' => 'text/plain' ],
	  [ "Redirecting to\n$url\n" ] ]
}

1;
