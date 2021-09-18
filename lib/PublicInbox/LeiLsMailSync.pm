# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# front-end for the "lei ls-mail-sync" sub-command
package PublicInbox::LeiLsMailSync;
use strict;
use v5.10.1;
use PublicInbox::LeiMailSync;

sub lei_ls_mail_sync {
	my ($lei, $filter) = @_;
	my $lms = $lei->lms or return;
	my $opt = $lei->{opt};
	my $re = $opt->{globoff} ? undef : $lei->glob2re($filter // '*');
	$re //= qr/\Q$filter\E/;
	my @f = $lms->folders;
	@f = $opt->{'invert-match'} ? grep(!/$re/, @f) : grep(/$re/, @f);
	if ($opt->{'local'} && !$opt->{remote}) {
		@f = grep(!m!\A[a-z\+]+://!i, @f);
	} elsif ($opt->{remote} && !$opt->{'local'}) {
		@f = grep(m!\A[a-z\+]+://!i, @f);
	}
	my $ORS = $opt->{z} ? "\0" : "\n";
	$lei->out(join($ORS, @f, ''));
}

1;
