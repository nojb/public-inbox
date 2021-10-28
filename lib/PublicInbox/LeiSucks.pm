# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Undocumented hidden command somebody might discover if they're
# frustrated and need to report a bug.  There's no manpage and
# it won't show up in tab completions or help.
package PublicInbox::LeiSucks;
use strict;
use v5.10.1;
use Digest::SHA ();
use Config;
use POSIX ();
use PublicInbox::Config;
use PublicInbox::IPC;

sub lei_sucks {
	my ($lei, @argv) = @_;
	$lei->start_pager if -t $lei->{1};
	my ($os, undef, $rel, undef, $mac)= POSIX::uname();
	if ($mac eq 'x86_64' && $Config{ptrsize} == 4) {
		$mac .= $Config{cppsymbols} =~ /\b__ILP32__=1\b/ ?
			',u=x32' : ',u=x86';
	}
	eval { require PublicInbox };
	my $pi_ver = eval('$PublicInbox::VERSION') // '(???)';
	my $nproc = PublicInbox::IPC::detect_nproc() // '?';
	my @out = ("lei $pi_ver\n",
		"perl $Config{version} / $os $rel / $mac ".
		"ptrsize=$Config{ptrsize} nproc=$nproc\n");
	chomp(my $gv = `git --version` || "git missing");
	$gv =~ s/ version / /;
	my $json = ref(PublicInbox::Config->json);
	$json .= ' ' . eval('$'.$json.'::VERSION') if $json;
	$json ||= '(no JSON)';
	push @out, "$gv / $json\n";
	if (eval { require PublicInbox::Over }) {
		push @out, 'SQLite '.
			(eval('$DBD::SQLite::sqlite_version') // '(undef)') .
			', DBI '.(eval('$DBI::VERSION') // '(undef)') .
			', DBD::SQLite '.
			(eval('$DBD::SQLite::VERSION') // '(undef)')."\n";
	} else {
		push @out, "Unable to load DBI / DBD::SQLite: $@\n";
	}
	if (eval { require PublicInbox::Search } &&
			PublicInbox::Search::load_xapian()) {
		push @out, 'Xapian '.
			join('.', map {
				$PublicInbox::Search::Xap->can($_)->();
			} qw(major_version minor_version revision)) .
			", bindings: $PublicInbox::Search::Xap";
		my $xs_ver = eval '$'."$PublicInbox::Search::Xap".'::VERSION';
		push @out, $xs_ver ? " $xs_ver\n" : " SWIG\n";
	} else {
		push @out, "Xapian not available: $@\n";
	}
	my $dig = Digest::SHA->new(1);
	push @out, "public-inbox blob OIDs of loaded features:\n";
	for my $m (grep(m{^PublicInbox/}, sort keys %INC)) {
		my $f = $INC{$m} // next; # lazy require failed (missing dep)
		$dig->add('blob '.(-s $f)."\0");
		$dig->addfile($f);
		push @out, '  '.$dig->hexdigest.' '.$m."\n";
	}
	push @out, <<'EOM';
Let us know how it sucks!  Please include the above and any other
relevant information when sending plain-text mail to us at:
meta@public-inbox.org -- archives: https://public-inbox.org/meta/
EOM
	$lei->out(@out);
}

1;
