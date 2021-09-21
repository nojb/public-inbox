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

sub lcat_folder ($$;$$) {
	my ($lei, $folder, $beg, $end) = @_;
	my $lms = $lei->{-lms_ro} //= $lei->lms // return;
	my $folders = [ $folder ];
	eval { $lms->arg2folder($lei, $folders) };
	return $lei->child_error(0, "# unknown folder: $folder") if $@;
	my %range;
	if (defined($beg)) { # NNTP article range
		$range{min} = $beg;
		$range{max} = $end // $beg;
	}
	for my $f (@$folders) {
		my $fid = $lms->fid_for($f);
		push @{$lei->{lcat_todo}}, { fid => $fid, %range };
	}
}

sub lcat_imap_uri ($$) {
	my ($lei, $uri) = @_;
	# cf. LeiXSearch->lcat_dump
	my $lms = $lei->{-lms_ro} //= $lei->lms // return;
	if (defined $uri->uid) {
		push @{$lei->{lcat_todo}}, $lms->imap_oidhex($lei, $uri);
	} elsif (defined(my $fid = $lms->fid_for($$uri))) {
		push @{$lei->{lcat_todo}}, { fid => $fid };
	} else {
		lcat_folder($lei, $$uri);
	}
}

sub lcat_nntp_uri ($$) {
	my ($lei, $uri) = @_;
	my $mid = $uri->message; # already unescaped by URI::news
	return "mid:$mid" if defined($mid);
	my $lms = $lei->{-lms_ro} //= $lei->lms // return;
	my ($ng, $beg, $end) = $uri->group;
	$uri->group($ng);
	lcat_folder($lei, $$uri, $beg, $end);
	'""';
}

sub extract_1 ($$) {
	my ($lei, $x) = @_;
	if ($x =~ m!\b(maildir:.+)!i) {
		lcat_folder($lei, $1);
		'""'; # blank query, using {lcat_todo}
	} elsif ($x =~ m!\b(([a-z]+)://\S+)!i) {
		my ($u, $scheme) = ($1, $2);
		$u =~ s/[\>\]\)\,\.\;]+\z//;
		if ($scheme =~ m!\A(imaps?)\z!i) {
			require PublicInbox::URIimap;
			lcat_imap_uri($lei, PublicInbox::URIimap->new($u));
			return '""'; # blank query, using {lcat_todo}
		} elsif ($scheme =~ m!\A(?:nntps?|s?news)\z!i) {
			require PublicInbox::URInntps;
			$u = PublicInbox::URInntps->new($u);
			return lcat_nntp_uri($lei, $u);
		} # http, or something else:
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
		push @{$lei->{lcat_todo}}, $1; # cf. LeiToMail->wq_atexit_child
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
		if (my $term = extract_1($lei, $x)) {
			push @q, $term;
		} elsif ($strict) {
			return $lei->fail(<<"");
could not extract Message-ID from $x

		}
	}
	delete $lei->{-lms_ro};
	@q ? join(' OR ', @q) : $lei->fail("no Message-ID in: @argv");
}

sub _stdin { # PublicInbox::InputPipe::consume callback for --stdin
	my ($lei) = @_; # $_[1] = $rbuf
	if (defined($_[1])) {
		$_[1] eq '' and return eval {
			$lei->fchdir or return;
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
	$lei->ale->refresh_externals($lxs, $lei);
	$lei->_lei_store(1);
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

sub _complete_lcat {
	require PublicInbox::LeiRefreshMailSync;
	PublicInbox::LeiRefreshMailSync::_complete_refresh_mail_sync(@_);
	# TODO: message-ids?, blobs? could get expensive...
}

1;
