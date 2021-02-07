# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# -h/--help support for lei
package PublicInbox::LeiHelp;
use strict;
use v5.10.1;
use Text::Wrap qw(wrap);

my %NOHELP = map { $_ => 1 } qw(mfolder);

sub call {
	my ($self, $errmsg, $CMD, $OPTDESC) = @_;
	my $cmd = $self->{cmd} // 'COMMAND';
	my @info = @{$CMD->{$cmd} // [ '...', '...' ]};
	my @top = ($cmd, shift(@info) // ());
	my $cmd_desc = shift(@info);
	$cmd_desc = $cmd_desc->($self) if ref($cmd_desc) eq 'CODE';
	$cmd_desc =~ s/default: /default:\xa0/;
	my @opt_desc;
	my $lpad = 2;
	for my $sw (grep { !ref } @info) { # ("prio=s", "z", $GLP_PASS)
		my $desc = $OPTDESC->{"$cmd\t$sw"} // $OPTDESC->{$sw} // next;
		my $arg_vals = '';
		($arg_vals, $desc) = @$desc if ref($desc) eq 'ARRAY';

		# lower-case is a keyword (e.g. `content', `oid'),
		# ALL_CAPS is a string description (e.g. `PATH')
		if ($desc !~ /default/ && $arg_vals =~ /\b([a-z]+)[,\|]/) {
			$desc .= " (default:\xa0`$1')";
		} else {
			$desc =~ s/default: /default:\xa0/;
		}
		my (@vals, @s, @l);
		my $x = $sw;
		if ($x =~ s/!\z//) { # solve! => --no-solve
			$x =~ s/(\A|\|)/$1no-/g
		} elsif ($x =~ s/\+\z//) { # verbose|v+
		} elsif ($x =~ s/:.+//) { # optional args: $x = "mid:s"
			@vals = (' [', undef, ']');
		} elsif ($x =~ s/=.+//) { # required arg: $x = "type=s"
			@vals = (' ', undef);
		} # else: no args $x = 'thread|t'

		# we support underscore options from public-inbox-* commands;
		# but they've never been documented and will likely go away.
		# $x = help|h
		for (grep { !/_/ && !$NOHELP{$_} } split(/\|/, $x)) {
			length($_) > 1 ? push(@l, "--$_") : push(@s, "-$_");
		}
		if (!scalar(@vals)) { # no args 'thread|t'
		} elsif ($arg_vals =~ s/\A([A-Z_]+)\b//) { # "NAME"
			$vals[1] = $1;
		} else {
			$vals[1] = uc(substr($l[0], 2)); # "--type" => "TYPE"
		}
		if ($arg_vals =~ /([,\|])/) {
			my $sep = $1;
			my @allow = split(/\Q$sep\E/, $arg_vals);
			my $must = $sep eq '|' ? 'Must' : 'Can';
			@allow = map { length $_ ? "`$_'" : () } @allow;
			my $last = pop @allow;
			$desc .= "\n$must be one of: " .
				join(', ', @allow) . " or $last";
		}
		my $lhs = join(', ', @s, @l) . join('', @vals);
		if ($x =~ /\|\z/) { # "stdin|" or "clear|"
			$lhs =~ s/\A--/- , --/;
		} else {
			$lhs =~ s/\A--/    --/; # pad if no short options
		}
		$lpad = length($lhs) if length($lhs) > $lpad;
		push @opt_desc, $lhs, $desc;
	}
	my $msg = $errmsg ? "E: $errmsg\n" : '';
	$msg .= <<EOF;
usage: lei @top
$cmd_desc

EOF
	$lpad += 2;
	local $Text::Wrap::columns = 78 - $lpad;
	# local $Text::Wrap::break = ; # don't break on nbsp (\xa0)
	my $padding = ' ' x ($lpad + 2);
	while (my ($lhs, $rhs) = splice(@opt_desc, 0, 2)) {
		$msg .= '  '.pack("A$lpad", $lhs);
		$rhs = wrap('', '', $rhs);
		$rhs =~ s/\n/\n$padding/sg; # LHS pad continuation lines
		$msg .= $rhs;
		$msg .= "\n";
	}
	my $fd = $errmsg ? 2 : 1;
	$self->start_pager if -t $self->{$fd};
	$msg =~ s/\xa0/ /gs; # convert NBSP to SP
	print { $self->{$fd} } $msg;
	$self->x_it($errmsg ? (1 << 8) : 0); # stderr => failure
	undef;
}

1;
