# This library is free software; you can redistribute it and/or modify it
# under the same terms as Perl itself, either Perl version 5.8.0 or, at
# your option, any later version of Perl 5 you may have available.
#
# The license for this file differs from the rest of public-inbox.
#
# Workaround some bugs in upstream Mail::IMAPClient when
# compression is enabled:
# - reference cycle: https://rt.cpan.org/Ticket/Display.html?id=132654
# - read starvation: https://rt.cpan.org/Ticket/Display.html?id=132720
package PublicInbox::IMAPClient;
use strict;
use parent 'Mail::IMAPClient';
use Errno qw(EAGAIN);

# RFC4978 COMPRESS
sub compress {
    my ($self) = @_;

    # BUG? strict check on capability commented out for now...
    #my $can = $self->has_capability("COMPRESS")
    #return undef unless $can and $can eq "DEFLATE";

    $self->_imap_command("COMPRESS DEFLATE") or return undef;

    my $zcl = $self->_load_module("Compress-Zlib") or return undef;

    # give caller control of args if desired
    $self->Compress(
        [
            -WindowBits => -$zcl->MAX_WBITS(),
            -Level      => $zcl->Z_BEST_SPEED()
        ]
    ) unless ( $self->Compress and ref( $self->Compress ) eq "ARRAY" );

    my ( $rc, $do, $io );

    ( $do, $rc ) = Compress::Zlib::deflateInit( @{ $self->Compress } );
    unless ( $rc == $zcl->Z_OK ) {
        $self->LastError("deflateInit failed (rc=$rc)");
        return undef;
    }

    ( $io, $rc ) =
      Compress::Zlib::inflateInit( -WindowBits => -$zcl->MAX_WBITS() );
    unless ( $rc == $zcl->Z_OK ) {
        $self->LastError("inflateInit failed (rc=$rc)");
        return undef;
    }

    $self->{Prewritemethod} = sub {
        my ( $self, $string ) = @_;

        my ( $rc, $out1, $out2 );
        ( $out1, $rc ) = $do->deflate($string);
        ( $out2, $rc ) = $do->flush( $zcl->Z_PARTIAL_FLUSH() )
          unless ( $rc != $zcl->Z_OK );

        unless ( $rc == $zcl->Z_OK ) {
            $self->LastError("deflate/flush failed (rc=$rc)");
            return undef;
        }

        return $out1 . $out2;
    };

    # need to retain some state for Readmoremethod/Readmethod calls
    my ( $Zbuf, $Ibuf ) = ( "", "" );

    $self->{Readmoremethod} = sub {
        my $self = shift;
        return 1 if ( length($Zbuf) || length($Ibuf) );
        $self->__read_more(@_);
    };

    $self->{Readmethod} = sub {
        my ( $self, $fh, $buf, $len, $off ) = @_;

        # get more data, but empty $Ibuf first if any data is left
        my ( $lz, $li ) = ( length $Zbuf, length $Ibuf );
        if ( $lz || !$li ) {
            my $readlen = $self->Buffer || 4096;
            my $ret = sysread( $fh, $Zbuf, $readlen, length $Zbuf );
            $lz = length $Zbuf;
            return $ret if ( !$ret && !$lz );    # $ret is undef or 0
        }

        # accumulate inflated data in $Ibuf
        if ($lz) {
            my ( $tbuf, $rc ) = $io->inflate( \$Zbuf );
            unless ( $rc == $zcl->Z_OK ) {
                $self->LastError("inflate failed (rc=$rc)");
                return undef;
            }
            $Ibuf .= $tbuf;
            $li = length $Ibuf;
        }

        if ( !$li ) {
            # note: faking EAGAIN here is only safe with level-triggered
            # I/O readiness notifications (select, poll).  Refactoring
            # callers will be needed in the unlikely case somebody wants
            # to use edge-triggered notifications (EV_CLEAR, EPOLLET).
            $! = EAGAIN;
            return undef;
        }

        # pull desired length of data from $Ibuf
        my $tbuf = substr( $Ibuf, 0, $len );
        substr( $Ibuf, 0, $len ) = "";
        substr( $$buf, $off ) = $tbuf;

        return length $tbuf;
    };

    return $self;
}

1;
