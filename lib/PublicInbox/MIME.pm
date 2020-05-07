# This library is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.
#
# The license for this file differs from the rest of public-inbox.
#
# It monkey patches the "parts_multipart" subroutine with patches
# from Matthew Horsfall <wolfsage@gmail.com> at:
#
# git clone --mirror https://github.com/rjbs/Email-MIME.git refs/pull/28/head
#
# commit fe0eb870ab732507aa39a1070a2fd9435c7e4877
# ("Make sure we don't modify the body of a message when injecting a header.")
# commit 981d8201a7239b02114489529fd366c4c576a146
# ("GH #14 - Handle CRLF emails properly.")
# commit 2338d93598b5e8432df24bda8dfdc231bdeb666e
# ("GH #14 - Support multipart messages without content-type in subparts.")
#
# For Email::MIME >= 1.923 && < 1.935,
# commit dcef9be66c49ae89c7a5027a789bbbac544499ce
# ("removing all trailing newlines was too much")
# is also included
package PublicInbox::MIME;
use strict;
use warnings;
use base qw(Email::MIME);
use Email::MIME::ContentType;
use PublicInbox::MsgIter ();
$Email::MIME::ContentType::STRICT_PARAMS = 0;

if ($Email::MIME::VERSION <= 1.937) {
sub parts_multipart {
  my $self     = shift;
  my $boundary = $self->{ct}->{attributes}->{boundary};

  # Take a message, join all its lines together.  Now try to Email::MIME->new
  # it with 1.861 or earlier.  Death!  It tries to recurse endlessly on the
  # body, because every time it splits on boundary it gets itself. Obviously
  # that means it's a bogus message, but a mangled result (or exception) is
  # better than endless recursion. -- rjbs, 2008-01-07
  return $self->parts_single_part
    unless $boundary and $self->body_raw =~ /^--\Q$boundary\E\s*$/sm;

  $self->{body_raw} = Email::Simple::body($self);

  # rfc1521 7.2.1
  my ($body, $epilogue) = split /^--\Q$boundary\E--\s*$/sm, $self->body_raw, 2;

  # Split on boundaries, but keep blank lines after them intact
  my @bits = split /^--\Q$boundary\E\s*?(?=$self->{mycrlf})/m, ($body || '');

  Email::Simple::body_set($self, undef);

  # If there are no headers in the potential MIME part, it's just part of the
  # body.  This is a horrible hack, although it's debatable whether it was
  # better or worse when it was $self->{body} = shift @bits ... -- rjbs,
  # 2006-11-27
  Email::Simple::body_set($self, shift @bits) if ($bits[0] || '') !~ /.*:.*/;

  my $bits = @bits;

  my @parts;
  for my $bit (@bits) {
    # Parts don't need headers. If they don't have them, they look like this:
    #
    #   --90e6ba6e8d06f1723604fc1b809a
    #
    #   Part 2
    #
    #   Part 2a
    #
    # $bit will contain two new lines before Part 2.
    #
    # Anything with headers will only have one new line.
    #
    # RFC 1341 Section 7.2 says parts without headers are to be considered
    # plain US-ASCII text. -- alh
    # 2016-08-01
    my $added_header;

    if ($bit =~ /^(?:$self->{mycrlf}){2}/) {
      $bit = "Content-type: text/plain; charset=us-ascii" . $bit;

      $added_header = 1;
    }

    $bit =~ s/\A[\n\r]+//smg;
    $bit =~ s/(?<!\x0d)$self->{mycrlf}\Z//sm;

    my $email = (ref $self)->new($bit);

    if ($added_header) {
      # Remove our changes so we don't change the raw email content
      $email->header_str_set('Content-Type');
    }

    push @parts, $email;
  }

  $self->{parts} = \@parts;

  return @{ $self->{parts} };
}
}

no warnings 'once';
*each_part = \&PublicInbox::MsgIter::em_each_part;
1;
