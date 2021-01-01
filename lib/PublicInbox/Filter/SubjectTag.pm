# Copyright (C) 2017-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Filter for various [tags] in subjects
package PublicInbox::Filter::SubjectTag;
use strict;
use warnings;
use base qw(PublicInbox::Filter::Base);

sub new {
	my ($class, %opts) = @_;
	my $tag = delete $opts{-tag};
	die "tag not defined!\n" unless defined $tag && $tag ne '';
	my $self = $class->SUPER::new(%opts);
	$self->{tag_re} = qr/\A\s*(re:\s+|)\Q$tag\E\s*/i;
	$self;
}

sub scrub {
	my ($self, $mime) = @_;
	my $subj = $mime->header('Subject');
	if (defined $subj) {
		$subj =~ s/$self->{tag_re}/$1/; # $1 is "Re: "
		$mime->header_str_set('Subject', $subj);
	}
	$self->ACCEPT($mime);
}

# no suffix/article rejection for mirrors
sub delivery {
	my ($self, $mime) = @_;
	$self->scrub($mime);
}

1;
