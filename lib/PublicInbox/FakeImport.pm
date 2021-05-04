# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# pretend to do PublicInbox::Import::add for "lei index"
package PublicInbox::FakeImport;
use strict;
use PublicInbox::ContentHash qw(git_sha);

sub new { bless { bytes_added => 0 }, __PACKAGE__ }

sub add {
	my ($self, $eml, $check_cb, $smsg) = @_;
	$smsg->populate($eml);
	my $raw = $eml->as_string;
	$smsg->{blob} = git_sha(1, \$raw)->hexdigest;
	$smsg->set_bytes($raw, length($raw));
	if (my $oidx = delete $smsg->{-oidx}) { # used by LeiStore
		$oidx->vivify_xvmd($smsg) or return;
	}
	1;
}

1;
