# This library is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.
#
# This license differs from the rest of public-inbox
#
# Our own jwz-style threading class based on Mail::Thread from CPAN.
# Mail::Thread is unmaintained and unavailable on some distros.
# We also do not want pruning or subject grouping, since we want
# to encourage strict threading and hopefully encourage people
# to use proper In-Reply-To/References.
#
# This includes fixes from several open bugs for Mail::Thread
#
# Avoid circular references
# - https://rt.cpan.org/Public/Bug/Display.html?id=22817
#
# And avoid recursion in recurse_down:
# - https://rt.cpan.org/Ticket/Display.html?id=116727
# - http://bugs.debian.org/cgi-bin/bugreport.cgi?bug=833479
package PublicInbox::SearchThread;
use strict;
use warnings;
use PublicInbox::MID qw($MID_EXTRACT);

sub thread {
	my ($msgs, $ordersub, $ctx) = @_;
	my $id_table = {};

	# Sadly, we sort here anyways since the fill-in-the-blanks References:
	# can be shakier if somebody used In-Reply-To with multiple, disparate
	# messages.  So, take the client Date: into account since we can't
	# always determine ordering when somebody uses multiple In-Reply-To.
	# We'll trust the client Date: header here instead of the Received:
	# time since this is for display (and not retrieval)
	_add_message($id_table, $_) for sort { $a->{ds} <=> $b->{ds} } @$msgs;
	my $ibx = $ctx->{-inbox};
	my $rootset = [ grep {
			!delete($_->{parent}) && $_->visible($ibx)
		} values %$id_table ];
	$id_table = undef;
	$rootset = $ordersub->($rootset);
	$_->order_children($ordersub, $ctx) for @$rootset;
	$rootset;
}

sub _get_cont_for_id ($$) {
	my ($id_table, $mid) = @_;
	$id_table->{$mid} ||= PublicInbox::SearchThread::Msg->new($mid);
}

sub _add_message ($$) {
	my ($id_table, $smsg) = @_;

	# A. if id_table...
	my $this = _get_cont_for_id($id_table, $smsg->{mid});
	$this->{smsg} = $smsg;

	# saves around 4K across 1K messages
	# TODO: move this to a more appropriate place, breaks tests
	# if we do it during psgi_cull
	delete $smsg->{num};

	# B. For each element in the message's References field:
	defined(my $refs = $smsg->{references}) or return;

	# This loop exists to help fill in gaps left from missing
	# messages.  It is not needed in a perfect world where
	# everything is perfectly referenced, only the last ref
	# matters.
	my $prev;
	foreach my $ref ($refs =~ m/$MID_EXTRACT/go) {
		# Find a Container object for the given Message-ID
		my $cont = _get_cont_for_id($id_table, $ref);

		# Link the References field's Containers together in
		# the order implied by the References header
		#
		# * If they are already linked don't change the
		#   existing links
		# * Do not add a link if adding that link would
		#   introduce a loop...
		if ($prev &&
			!$cont->{parent} &&  # already linked
			!$cont->has_descendent($prev) # would loop
		   ) {
			$prev->add_child($cont);
		}
		$prev = $cont;
	}

	# C. Set the parent of this message to be the last element in
	# References.
	if (defined $prev && !$this->has_descendent($prev)) { # would loop
		$prev->add_child($this);
	}
}

package PublicInbox::SearchThread::Msg;
use strict;
use warnings;
use Carp qw(croak);

sub new {
	bless {
		id => $_[1],
		children => {}, # becomes an array when sorted by ->order(...)
	}, $_[0];
}

sub topmost {
	my ($self) = @_;
	my @q = ($self);
	while (my $cont = shift @q) {
		return $cont if $cont->{smsg};
		push @q, values %{$cont->{children}};
	}
	undef;
}

sub add_child {
	my ($self, $child) = @_;
	croak "Cowardly refusing to become my own parent: $self"
	  if $self == $child;

	my $cid = $child->{id};

	# reparenting:
	if (defined(my $parent = $child->{parent})) {
		delete $parent->{children}->{$cid};
	}

	$self->{children}->{$cid} = $child;
	$child->{parent} = $self;
}

sub has_descendent {
	my ($self, $child) = @_;
	my %seen; # loop prevention
	while ($child) {
		return 1 if $self == $child || $seen{$child}++;
		$child = $child->{parent};
	}
	0;
}

# Do not show/keep ghosts iff they have no children.  Sometimes
# a ghost Message-ID is the result of a long header line
# being folded/mangled by a MUA, and not a missing message.
sub visible ($$) {
	my ($self, $ibx) = @_;
	($self->{smsg} ||= eval { $ibx->smsg_by_mid($self->{id}) }) ||
	 (scalar values %{$self->{children}});
}

sub order_children {
	my ($cur, $ordersub, $ctx) = @_;

	my %seen = ($cur => 1); # self-referential loop prevention
	my @q = ($cur);
	my $ibx = $ctx->{-inbox};
	while (defined($cur = shift @q)) {
		my $c = $cur->{children}; # The hashref here...

		$c = [ grep { !$seen{$_}++ && visible($_, $ibx) } values %$c ];
		$c = $ordersub->($c) if scalar @$c > 1;
		$cur->{children} = $c; # ...becomes an arrayref
		push @q, @$c;
	}
}

1;
