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
use Email::Abstract;

sub new {
	return bless {
		messages => $_[1],
		id_table => {},
		rootset  => []
	}, $_[0];
}

sub _get_hdr {
	my ($class, $msg, $hdr) = @_;
	Email::Abstract->get_header($msg, $hdr) || '';
}

sub _uniq {
	my %seen;
	return grep { !$seen{$_}++ } @_;
}

sub _references {
	my $class = shift;
	my $msg = shift;
	my @references = ($class->_get_hdr($msg, "References") =~ /<([^>]+)>/g);
	my $foo = $class->_get_hdr($msg, "In-Reply-To");
	chomp $foo;
	$foo =~ s/.*?<([^>]+)>.*/$1/;
	push @references, $foo
	  if $foo =~ /^\S+\@\S+$/ && (!@references || $references[-1] ne $foo);
	return _uniq(@references);
}

sub _msgid {
	my ($class, $msg) = @_;
	my $id = $class->_get_hdr($msg, "Message-ID");
	die "attempt to thread message with no id" unless $id;
	chomp $id;
	$id =~ s/^<([^>]+)>.*/$1/; # We expect this not to have <>s
	return $id;
}

sub rootset { @{$_[0]{rootset}} }

sub thread {
	my $self = shift;
	$self->_setup();
	$self->{rootset} = [
			grep { !$_->{parent} } values %{$self->{id_table}} ];
	$self->_finish();
}

sub _finish {
	my $self = shift;
	delete $self->{id_table};
	delete $self->{seen};
}

sub _get_cont_for_id {
	my $self = shift;
	my $id = shift;
	$self->{id_table}{$id} ||= $self->_container_class->new($id);
}

sub _container_class { 'PublicInbox::SearchThread::Container' }

sub _setup {
	my ($self) = @_;

	_add_message($self, $_) foreach @{$self->{messages}};
}

sub _add_message ($$) {
	my ($self, $message) = @_;

	# A. if id_table...
	my $this_container = $self->_get_cont_for_id($self->_msgid($message));
	$this_container->{message} = $message;

	# B. For each element in the message's References field:
	my @refs = $self->_references($message);

	my $prev;
	for my $ref (@refs) {
		# Find a Container object for the given Message-ID
		my $container = $self->_get_cont_for_id($ref);

		# Link the References field's Containers together in the
		# order implied by the References header
		# * If they are already linked don't change the existing links
		# * Do not add a link if adding that link would introduce
		#   a loop...

		if ($prev &&
			!$container->{parent} &&  # already linked
			!$container->has_descendent($prev) # would loop
		   ) {
			$prev->add_child($container);
		}
		$prev = $container;
	}

	# C. Set the parent of this message to be the last element in
	# References...
	if ($prev &&
		!$this_container->has_descendent($prev) # would loop
	   ) {
		$prev->add_child($this_container)
	}
}

sub order {
	my $self = shift;
	my $ordersub = shift;

	# make a fake root
	my $root = $self->_container_class->new( 'fakeroot' );
	$root->add_child( $_ ) for @{ $self->{rootset} };

	# sort it
	$root->order_children( $ordersub );

	# and untangle it
	my $kids = $root->children;
	$self->{rootset} = $kids;
	$root->remove_child($_) for @$kids;
}

package PublicInbox::SearchThread::Container;
use Carp qw(croak);
use Scalar::Util qw(weaken);

sub new { my $self = shift; bless { id => shift }, $self; }

sub message { $_[0]->{message} }
sub child { $_[0]->{child} }
sub next { $_[0]->{next} }
sub messageid { $_[0]->{id} }

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
	my $self = shift;
	my $child = shift;
	die "Assertion failed: $child" unless eval {$child};
	my $there = 0;
	$self->recurse_down(sub { $there = 1 if $_[0] == $child });

	return $there;
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
	my $self = shift;
	my $ordersub = shift;

	return unless $ordersub;

	my $sub = sub {
		my $cont = shift;
		my $children = $cont->children;
		return if @$children < 2;
		$cont->set_children( $ordersub->( $children ) );
	};
	$self->iterate_down( undef, $sub );
	undef $sub;
}

# non-recursive version of recurse_down to avoid stack depth warnings
sub recurse_down {
	my ($self, $callback) = @_;
	my %seen;
	my @q = ($self);
	while (my $cont = shift @q) {
		$seen{$cont}++;
		$callback->($cont);

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
}

sub iterate_down {
	my $self = shift;
	my ($before, $after) = @_;

	my %seen;
	my $walk = $self;
	my $depth = 0;
	my @visited;
	while ($walk) {
		push @visited, [ $walk, $depth ];
		$before->($walk, $depth) if $before;

		# spot/break loops
		$seen{$walk}++;

		my $child = $walk->{child};
		if ($child && $seen{$child}) {
			$walk->{child} = $child = undef;
		}

		my $next = $walk->{next};
		if ($next && $seen{$next}) {
			$walk->{next} = $next = undef;
		}

		# go down, or across
		if ($child) {
			$next = $child;
			++$depth;
		}

		# no next?  look up
		if (!$next) {
			my $up = $walk;
			while ($up && !$next) {
				$up = $up->{parent};
				--$depth;
				$next = $up->{next} if $up;
			}
		}
		$walk = $next;
	}
	return unless $after;
	while (@visited) { $after->(@{ pop @visited }) }
}

1;
