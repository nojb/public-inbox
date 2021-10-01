# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Intended for PublicInbox::DS::event_loop in read-only daemons
# to avoid each_inbox() monopolizing the event loop when hundreds/thousands
# of inboxes are in play.
package PublicInbox::ConfigIter;
use strict;
use v5.10.1;

sub new {
	my ($class, $pi_cfg, $cb, @args) = @_;
	my $i = 0;
	bless [ $pi_cfg, \$i, $cb, @args ], __PACKAGE__;
}

# for PublicInbox::DS::next_tick, we only call this is if
# PublicInbox::DS is already loaded
sub event_step {
	my $self = shift;
	my ($pi_cfg, $i, $cb, @arg) = @$self;
	my $section = $pi_cfg->{-section_order}->[$$i++];
	eval { $cb->($pi_cfg, $section, @arg) };
	warn "E: $@ in ${self}::event_step" if $@;
	PublicInbox::DS::requeue($self) if defined($section);
}

# for generic PSGI servers
sub each_section {
	my $self = shift;
	my ($pi_cfg, $i, $cb, @arg) = @$self;
	while (defined(my $section = $pi_cfg->{-section_order}->[$$i++])) {
		eval { $cb->($pi_cfg, $section, @arg) };
		warn "E: $@ in ${self}::each_section" if $@;
	}
	eval { $cb->($pi_cfg, undef, @arg) };
	warn "E: $@ in ${self}::each_section" if $@;
}

1;
