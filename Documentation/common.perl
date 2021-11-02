#!perl -w
# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use Fcntl qw(SEEK_SET);
my $have_search = eval { require PublicInbox::Search; 1 };
my $addr = 'meta@public-inbox.org';
for my $pod (@ARGV) {
	open my $fh, '+<', $pod or die "open($pod): $!";
	my $s = do { local $/; <$fh> } // die "read $!";
	my $orig = $s;
	$s =~ s!^=head1 COPYRIGHT\n.+?^=head1([^\n]+)\n!=head1 COPYRIGHT

Copyright all contributors L<mailto:$addr>

License: AGPL-3.0+ L<https://www.gnu.org/licenses/agpl-3.0.txt>

=head1$1
		!ms;

	$s =~ s!^=head1 CONTACT\n.+?^=head1([^\n]+)\n!=head1 CONTACT

Feedback welcome via plain-text mail to L<mailto:$addr>

The mail archives are hosted at L<https://public-inbox.org/meta/> and
L<http://4uok3hntl7oi7b4uf4rtfwefqeexfzil2w6kgk2jn5z2f764irre7byd.onion/meta/>

=head1$1
		!ms;
	$have_search and $s =~ s!^=for\scomment\n
			^AUTO-GENERATED-SEARCH-TERMS-BEGIN\n
			.+?
			^=for\scomment\n
			^AUTO-GENERATED-SEARCH-TERMS-END\n
			!search_terms()!emsx;
	$s =~ s/[ \t]+$//sgm;
	next if $s eq $orig;
	seek($fh, 0, SEEK_SET) or die "seek: $!";
	truncate($fh, 0) or die "truncate: $!";
	print $fh $s or die "print: $!";
	close $fh or die "close: $!";
}

sub search_terms {
	my $help = eval('\@PublicInbox::Search::HELP');
	my $s = '';
	my $pad = 0;
	my $i;
	for ($i = 0; $i < @$help; $i += 2) {
		my $pfx = $help->[$i];
		my $n = length($pfx);
		$pad = $n if $n > $pad;
		$s .= $pfx . "\0";
		$s .= $help->[$i + 1];
		$s .= "\f\n";
	}
	$pad += 2;
	my $padding = ' ' x ($pad + 4);
	$s =~ s/^/$padding/gms;
	$s =~ s/^$padding(\S+)\0/"    $1".(' ' x ($pad - length($1)))/egms;
	$s =~ s/\f\n/\n/gs;
	$s =~ s/^  //gms;
	substr($s, 0, 0, "=for comment\nAUTO-GENERATED-SEARCH-TERMS-BEGIN\n\n");
	$s .= "\n=for comment\nAUTO-GENERATED-SEARCH-TERMS-END\n";
}
