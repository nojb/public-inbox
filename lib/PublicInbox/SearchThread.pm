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
	$self->{rootset} = [
			grep { !$_->{parent} } values %{$self->{id_table}} ];
	delete $self->{id_table};
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
	my $prev;
	if (defined(my $refs = $smsg->{references})) {
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
	}

	# C. Set the parent of this message to be the last element in
	# References...
	if ($prev && !$this->has_descendent($prev)) { # would loop
		$prev->add_child($this)
	}
}

sub order {
	my ($self, $ordersub) = @_;

	# make a fake root
	my $root = _get_cont_for_id($self, 'fakeroot');
	$root->add_child( $_ ) for @{ $self->{rootset} };

	# sort it
	$root->order_children( $ordersub );

	# and untangle it
	my $kids = $root->children;
	$self->{rootset} = $kids;
	$root->remove_child($_) for @$kids;
}

package PublicInbox::SearchThread::Msg;
use Carp qw(croak);
use Scalar::Util qw(weaken);

sub new { my $self = shift; bless { id => shift }, $self; }

sub add_child {
	my ($self, $child) = @_;
	croak "Cowardly refusing to become my own parent: $self"
	  if $self == $child;

	if (grep { $_ == $child } @{$self->children}) {
		# All is potentially correct with the world
		weaken($child->{parent} = $self);
		return;
	}

	my $parent = $child->{parent};
	remove_child($parent, $child) if $parent;

	$child->{next} = $self->{child};
	$self->{child} = $child;
	weaken($child->{parent} = $self);
}

sub remove_child {
	my ($self, $child) = @_;

	my $x = $self->{child} or return;
	if ($x == $child) {  # First one's easy.
		$self->{child} = $child->{next};
		$child->{parent} = $child->{next} = undef;
		return;
	}

	my $prev = $x;
	while ($x = $x->{next}) {
		if ($x == $child) {
			$prev->{next} = $x->{next}; # Unlink x
			$x->{next} = $x->{parent} = undef; # Deparent it
			return;
		}
		$prev = $x;
	}
	# oddly, we can get here
	$child->{next} = $child->{parent} = undef;
}

sub has_descendent {
	my ($self, $child) = @_;
	my %seen;
	my @q = ($self);
	while (my $cont = shift @q) {
		$seen{$cont} = 1;

		return 1 if $cont == $child;

		if (my $next = $cont->{next}) {
			if ($seen{$next}) {
				$cont->{next} = undef;
			} else {
				push @q, $next;
			}
		}
		if (my $child = $cont->{child}) {
			if ($seen{$child}) {
				$cont->{child} = undef;
			} else {
				push @q, $child;
			}
		}
	}
	0;
}

sub children {
	my $self = shift;
	my @children;
	my $visitor = $self->{child};
	while ($visitor) {
		push @children, $visitor;
		$visitor = $visitor->{next};
	}
	\@children;
}

sub set_children {
	my ($self, $children) = @_;
	my $walk = $self->{child} = shift @$children;
	do {
		$walk = $walk->{next} = shift @$children;
	} while ($walk);
}

sub order_children {
	my ($walk, $ordersub) = @_;

	my %seen;
	my @visited;
	while ($walk) {
		push @visited, $walk;

		# spot/break loops
		$seen{$walk} = 1;

		my $child = $walk->{child};
		if ($child && $seen{$child}) {
			$walk->{child} = $child = undef;
		}

		my $next = $walk->{next};
		if ($next && $seen{$next}) {
			$walk->{next} = $next = undef;
		}

		# go down, or across
		$next = $child if $child;

		# no next?  look up
		if (!$next) {
			my $up = $walk;
			while ($up && !$next) {
				$up = $up->{parent};
				$next = $up->{next} if $up;
			}
		}
		$walk = $next;
	}
	foreach my $cont (@visited) {
		my $children = $cont->children;
		next if @$children < 2;
		$children = $ordersub->($children);
		$cont = $cont->{child} = shift @$children;
		do {
			$cont = $cont->{next} = shift @$children;
		} while ($cont);
	}
}

1;
