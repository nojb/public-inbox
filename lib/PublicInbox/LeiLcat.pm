# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# lcat: local cat, display a local message by Message-ID or blob,
# extracting from URL necessary
# "lei lcat <URL|SPEC>"
package PublicInbox::LeiLcat;
use strict;
use v5.10.1;
use PublicInbox::LeiViewText;
use URI::Escape qw(uri_unescape);
use PublicInbox::MID qw($MID_EXTRACT);

sub lcat_imap_uid_uri ($$) {
	my ($lei, $uid_uri) = @_;
	my $lms = $lei->{lse}->lms or return;
	my $oidhex = $lms->imap_oid($lei, $uid_uri);
	if (ref(my $err = $oidhex)) { # art2folder error
		$lei->qerr(@{$err->{qerr}}) if $err->{qerr};
	}
	push @{$lei->{lcat_blob}}, $oidhex; # cf. LeiToMail->wq_atexit_child
}

sub extract_1 ($$) {
	my ($lei, $x) = @_;
	if ($x =~ m!\b(imaps?://[^>]+)!i) {
		my $u = $1;
		require PublicInbox::URIimap;
		$u = PublicInbox::URIimap->new($u);
		defined($u->uid) ? lcat_imap_uid_uri($lei, $u) :
				$lei->child_error(1 << 8, "# no UID= in $u");
		'""'; # blank query, using {lcat_blob}
	} elsif ($x =~ m!\b([a-z]+?://\S+)!i) {
		my $u = $1;
		$u =~ s/[\>\]\)\,\.\;]+\z//;
		require URI;
		$u = URI->new($u);
		my $p = $u->path;
		my $term;
		if ($p =~ m!([^/]+\@[^/]+)!) { # common msgid pattern
			$term = 'mid:'.uri_unescape($1);

			# is it a URL which returns the full thread?
			if ($u->scheme =~ /\Ahttps?/i &&
				$p =~ m!/(?:T/?|t/?|t\.mbox\.gz|t\.atom)\b!) {

				$lei->{mset_opt}->{threads} = 1;
			}
		} elsif ($u->scheme =~ /\Ahttps?/i &&
				# some msgids don't have '@', see if it looks like
				# a public-inbox URL:
				$p =~ m!/([^/]+)/(raw|t/?|T/?|
					t\.mbox\.gz|t\.atom)\z!x) {
			$lei->{mset_opt}->{threads} = 1 if $2 && $2 ne 'raw';
			$term = 'mid:'.uri_unescape($1);
		}
		$term;
	} elsif ($x =~ $MID_EXTRACT) { # <$MSGID>
		"mid:$1";
	} elsif ($x =~ /\b((?:m|mid):\S+)/) { # our own prefixes (and mairix)
		$1;
	} elsif ($x =~ /\bid:(\S+)/) { # notmuch convention
		"mid:$1";
	} elsif ($x =~ /\bblob:([0-9a-f]{7,})\b/) {
		push @{$lei->{lcat_blob}}, $1; # cf. LeiToMail->wq_atexit_child
		'""'; # blank query
	} else {
		undef;
	}
}

sub extract_all {
	my ($lei, @argv) = @_;
	my $strict = !$lei->{opt}->{stdin};
	my @q;
	for my $x (@argv) {
		if (my $term = extract_1($lei,$x)) {
			push @q, $term;
		} elsif ($strict) {
			return $lei->fail(<<"");
could not extract Message-ID from $x

		}
	}
	@q ? join(' OR ', @q) : $lei->fail("no Message-ID in: @argv");
}

sub _stdin { # PublicInbox::InputPipe::consume callback for --stdin
	my ($lei) = @_; # $_[1] = $rbuf
	if (defined($_[1])) {
		$_[1] eq '' and return eval {
			if (my $dfd = $lei->{3}) {
				chdir($dfd) or return $lei->fail("fchdir: $!");
			}
			my @argv = split(/\s+/, $lei->{mset_opt}->{qstr});
			$lei->{mset_opt}->{qstr} = extract_all($lei, @argv)
				or return;
			$lei->_start_query;
		};
		$lei->{mset_opt}->{qstr} .= $_[1];
	} else {
		$lei->fail("error reading stdin: $!");
	}
}

sub lei_lcat {
	my ($lei, @argv) = @_;
	my $lxs = $lei->lxs_prepare or return;
	$lei->ale->refresh_externals($lxs);
	my $sto = $lei->_lei_store(1);
	$lei->{lse} = $sto->search;
	my $opt = $lei->{opt};
	my %mset_opt = map { $_ => $opt->{$_} } qw(threads limit offset);
	$mset_opt{asc} = $opt->{'reverse'} ? 1 : 0;
	$mset_opt{limit} //= 10000;
	$opt->{sort} //= 'relevance';
	$mset_opt{relevance} = 1;
	$lei->{mset_opt} = \%mset_opt;
	$opt->{'format'} //= 'text' unless defined($opt->{output});
	if ($lei->{opt}->{stdin}) {
		return $lei->fail(<<'') if @argv;
no args allowed on command-line with --stdin

		require PublicInbox::InputPipe;
		PublicInbox::InputPipe::consume($lei->{0}, \&_stdin, $lei);
		return;
	}
	$lei->{mset_opt}->{qstr} = extract_all($lei, @argv) or return;
	$lei->_start_query;
}

1;
