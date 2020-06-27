# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
package PublicInbox::GitCredential;
use strict;
use PublicInbox::Spawn qw(popen_rd);

sub run ($$) {
	my ($self, $op) = @_;
	my ($in_r, $in_w);
	pipe($in_r, $in_w) or die "pipe: $!";
	my $out_r = popen_rd([qw(git credential), $op], undef, { 0 => $in_r });
	close $in_r or die "close in_r: $!";

	my $out = '';
	for my $k (qw(url protocol host username password)) {
		defined(my $v = $self->{$k}) or next;
		die "`$k' contains `\\n' or `\\0'\n" if $v =~ /[\n\0]/;
		$out .= "$k=$v\n";
	}
	$out .= "\n";
	print $in_w $out or die "print (git credential $op): $!";
	close $in_w or die "close (git credential $op): $!";
	return $out_r if $op eq 'fill';
	<$out_r> and die "unexpected output from `git credential $op'\n";
	close $out_r or die "`git credential $op' failed: \$!=$! \$?=$?\n";
}

sub fill {
	my ($self) = @_;
	my $out_r = run($self, 'fill');
	while (<$out_r>) {
		chomp;
		return if $_ eq '';
		/\A([^=]+)=(.*)\z/ or die "bad line: $_\n";
		$self->{$1} = $2;
	}
	close $out_r or die "git credential fill failed: \$!=$! \$?=$?\n";
}

1;
