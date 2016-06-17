# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# base class for creating per-list or per-project filters
package PublicInbox::Filter::Base;
use strict;
use warnings;
use PublicInbox::MsgIter;
use constant MAX_MID_SIZE => 244; # max term size - 1 in Xapian

sub No ($) { "*** We only accept plain-text mail, No $_[0] ***" }

our %DEFAULTS = (
	reject_suffix => [ qw(exe bat cmd com pif scr vbs cpl zip swf swfl) ],
	reject_type => [ 'text/html:'.No('HTML'), 'text/xhtml:'.No('HTML'),
		'application/vnd.*:'.No('vendor-specific formats'),
		'image/*:'.No('images'), 'video/*:'.No('video'),
		'audio/*:'.No('audio') ],
);
our $INVALID_FN = qr/\0/;

sub REJECT () { 100 }
sub ACCEPT { scalar @_ > 1 ? $_[1] : 1 }
sub IGNORE () { 0 }

my %patmap = ('*' => '.*', '?' => '.', '[' => '[', ']' => ']');
sub glob2pat {
	my ($glob) = @_;
        $glob =~ s!(.)!$patmap{$1} || "\Q$1"!ge;
        $glob;
}

sub new {
	my ($class, %opts) = @_;
	my $self = bless { err => '', %opts }, $class;
	foreach my $f (qw(reject_suffix reject_type)) {
		# allow undef:
		$self->{$f} = $DEFAULTS{$f} unless exists $self->{$f};
	}
	if (defined $self->{reject_suffix}) {
		my $tmp = $self->{reject_suffix};
		$tmp = join('|', map { glob2pat($_) } @$tmp);
		$self->{reject_suffix} = qr/\.($tmp)\s*\z/i;
	}
	my $rt = [];
	if (defined $self->{reject_type}) {
		my $tmp = $self->{reject_type};
		@$rt = map {
			my ($type, $msg) = split(':', $_, 2);
			$type = lc $type;
			$msg ||= "Unacceptable Content-Type: $type";
			my $re = glob2pat($type);
			[ qr/\b$re\b/i, $msg ];
		} @$tmp;
	}
	$self->{reject_type} = $rt;
	$self;
}

sub reject ($$) {
	my ($self, $reason) = @_;
	$self->{err} = $reason;
	REJECT;
}

sub err ($) { $_[0]->{err} }

# by default, scrub is a no-op, see PublicInbox::Filter::Vger::scrub
# for an example of the override
sub scrub {
	my ($self, $mime) = @_;
	$self->ACCEPT($mime);
}

# for MDA
sub delivery {
	my ($self, $mime) = @_;

	my $rt = $self->{reject_type};
	my $reject_suffix = $self->{reject_suffix} || $INVALID_FN;
	my (%sfx, %type);

	msg_iter($mime, sub {
		my ($part, $depth, @idx) = @{$_[0]};

		my $ct = $part->content_type || 'text/plain';
		foreach my $p (@$rt) {
			if ($ct =~ $p->[0]) {
				$type{$p->[1]} = 1;
			}
		}

		my $fn = $part->filename;
		if (defined($fn) && $fn =~ $reject_suffix) {
			$sfx{$1} = 1;
		}
	});

	my @r;
	if (keys %type) {
		push @r, sort keys %type;
	}
	if (keys %sfx) {
		push @r, 'Rejected suffixes(s): '.join(', ', sort keys %sfx);
	}

	@r ? $self->reject(join("\n", @r)) : $self->scrub($mime);
}

1;
