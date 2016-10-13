# This library is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.
#
# This license differs from the rest of public-inbox
#
# Our own jwz-style threading class based on Mail::Thread from CPAN.
# Mail::Thread is unmaintained and available on some distros.
# We also do not want pruning or subject grouping, since we want
# to encourage strict threading and hopefully encourage people
# to use proper In-Reply-To.
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

sub new {
	return bless {
		messages => $_[1],
		id_table => {},
		rootset  => []
	}, $_[0];
}

sub thread {
	my $self = shift;
	_add_message($self, $_) foreach @{$self->{messages}};
	my $id_table = delete $self->{id_table};
	$self->{rootset} = [ grep { !delete $_->{parent} } values %$id_table ];
}

sub _get_cont_for_id ($$) {
	my ($self, $mid) = @_;
	$self->{id_table}{$mid} ||= PublicInbox::SearchThread::Msg->new($mid);
}

sub _add_message ($$) {
	my ($self, $smsg) = @_;

	# A. if id_table...
	my $this = _get_cont_for_id($self, $smsg->{mid});
	$this->{smsg} = $smsg;

	# B. For each element in the message's References field:
	defined(my $refs = $smsg->{references}) or return;

	my $prev;
	foreach my $ref ($refs =~ m/<([^>]+)>/g) {
		# Find a Container object for the given Message-ID
		my $cont = _get_cont_for_id($self, $ref);

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
	# References...
	if ($prev && !$this->has_descendent($prev)) { # would loop
		$prev->add_child($this)
	}
}

sub order {
	my ($self, $ordersub) = @_;
	my $rootset = $ordersub->($self->{rootset});
	$self->{rootset} = $rootset;
	$_->order_children($ordersub) for @$rootset;
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
	while ($child) {
		return 1 if $self == $child;
		$child = $child->{parent};
	}
	0;
}

sub order_children {
	my ($cur, $ordersub) = @_;

	my %seen = ($cur => 1);
	my @q = ($cur);
	while (defined($cur = shift @q)) {
		my $c = $cur->{children}; # The hashref here...

		$c = [ grep { !$seen{$_}++ } values %$c ]; # spot/break loops
		$c = $ordersub->($c) if scalar @$c > 1;
		$cur->{children} = $c; # ...becomes an arrayref
		push @q, @$c;
	}
}

1;
