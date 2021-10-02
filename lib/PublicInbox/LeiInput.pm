# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# parent class for LeiImport, LeiConvert, LeiIndex
package PublicInbox::LeiInput;
use strict;
use v5.10.1;
use PublicInbox::DS;
use PublicInbox::Spawn qw(which popen_rd);
use PublicInbox::InboxWritable qw(eml_from_path);

# JMAP RFC 8621 4.1.1
# https://www.iana.org/assignments/imap-jmap-keywords/imap-jmap-keywords.xhtml
our @KW = (qw(seen answered flagged draft), # widely-compatible
	qw(forwarded), # IMAP + Maildir
	qw(phishing junk notjunk)); # rarely supported

# note: RFC 8621 states "Users may add arbitrary keywords to an Email",
# but is it good idea?  Stick to the system and reserved ones, for now.
# The widely-compatible ones map to IMAP system flags, Maildir flags
# and mbox Status/X-Status headers.
my %KW = map { $_ => 1 } @KW;
my $L_MAX = 244; # Xapian term limit - length('L')

# RFC 8621, sec 2 (Mailboxes) a "label" for us is a JMAP Mailbox "name"
# "Servers MAY reject names that violate server policy"
my %ERR = (
	L => sub {
		my ($label) = @_;
		length($label) >= $L_MAX and
			return "`$label' too long (must be <= $L_MAX)";
		$label =~ m{\A[a-z0-9_](?:[a-z0-9_\-\./\@,]*[a-z0-9])?\z}i ?
			undef : "`$label' is invalid";
	},
	kw => sub {
		my ($kw) = @_;
		$KW{$kw} ? undef : <<EOM;
`$kw' is not one of: `seen', `flagged', `answered', `draft'
`junk', `notjunk', `phishing' or `forwarded'
EOM
	}
);

sub check_input_format ($;$) {
	my ($lei, $files) = @_;
	my $opt_key = 'in-format';
	my $fmt = $lei->{opt}->{$opt_key};
	if (!$fmt) {
		my $err = $files ? "regular file(s):\n@$files" : '--stdin';
		return $lei->fail("--$opt_key unset for $err");
	}
	return 1 if $fmt eq 'eml';
	require PublicInbox::MboxLock if $files;
	require PublicInbox::MboxReader;
	PublicInbox::MboxReader->reads($fmt) or
		return $lei->fail("--$opt_key=$fmt unrecognized");
	1;
}

sub input_mbox_cb { # base MboxReader callback
	my ($eml, $self) = @_;
	$eml->header_set($_) for (qw(Status X-Status));
	$self->input_eml_cb($eml);
}

# import a single file handle of $name
# Subclass must define ->input_eml_cb and ->input_mbox_cb
sub input_fh {
	my ($self, $ifmt, $fh, $name, @args) = @_;
	if ($ifmt eq 'eml') {
		my $buf = do { local $/; <$fh> } //
			return $self->{lei}->child_error(0, <<"");
error reading $name: $!

		# mutt pipes single RFC822 messages with a "From " line,
		# but no Content-Length or "From " escaping.
		# "git format-patch" also generates such files by default.
		$buf =~ s/\A[\r\n]*From [^\r\n]*\r?\n//s;

		# a user may feed just a body: git diff | lei rediff -U9
		if ($self->{-force_eml}) {
			my $eml = PublicInbox::Eml->new($buf);
			substr($buf, 0, 0) = "\n\n" if !$eml->{bdy};
		}
		$self->input_eml_cb(PublicInbox::Eml->new(\$buf), @args);
	} else {
		# prepare_inputs already validated $ifmt
		my $cb = PublicInbox::MboxReader->reads($ifmt) //
				die "BUG: bad fmt=$ifmt";
		$cb->(undef, $fh, $self->can('input_mbox_cb'), $self, @args);
	}
}

# handles mboxrd endpoints described in Documentation/design_notes.txt
sub handle_http_input ($$@) {
	my ($self, $url, @args) = @_;
	my $lei = $self->{lei} or die 'BUG: {lei} missing';
	my $curl_opt = delete $self->{"-curl-$url"} or
				die("BUG: $url curl options not prepared");
	my $uri = pop @$curl_opt;
	my $curl = PublicInbox::LeiCurl->new($lei, $self->{curl}) or return;
	push @$curl, '-s', @$curl_opt;
	my $cmd = $curl->for_uri($lei, $uri);
	$lei->qerr("# $cmd");
	my $rdr = { 2 => $lei->{2}, pgid => 0 };
	my ($fh, $pid) = popen_rd($cmd, undef, $rdr);
	grep(/\A--compressed\z/, @$curl) or
		$fh = IO::Uncompress::Gunzip->new($fh, MultiStream => 1);
	eval { $self->input_fh('mboxrd', $fh, $url, @args) };
	my $err = $@;
	waitpid($pid, 0);
	$? || $err and
		$lei->child_error($?, "@$cmd failed".$err ? " $err" : '');
}

sub input_path_url {
	my ($self, $input, @args) = @_;
	my $lei = $self->{lei};
	my $ifmt = lc($lei->{opt}->{'in-format'} // '');
	# TODO auto-detect?
	if ($input =~ m!\Aimaps?://!i) {
		$lei->{net}->imap_each($input, $self->can('input_net_cb'),
						$self, @args);
		return;
	} elsif ($input =~ m!\A(?:nntps?|s?news)://!i) {
		$lei->{net}->nntp_each($input, $self->can('input_net_cb'),
						$self, @args);
		return;
	} elsif ($input =~ m!\Ahttps?://!i) {
		handle_http_input($self, $input, @args);
		return;
	}

	# local-only below
	my $ifmt_pfx = '';
	if ($input =~ s!\A([a-z0-9]+):!!i) {
		$ifmt_pfx = "$1:";
		$ifmt = lc($1);
	} elsif ($input =~ /\.(?:patch|eml)\z/i) {
		$ifmt = 'eml';
	} elsif (-f $input && $input =~ m{\A(?:.+)/(?:new|cur)/([^/]+)\z}) {
		my $bn = $1;
		my $fl = PublicInbox::MdirReader::maildir_basename_flags($bn);
		return if index($fl, 'T') >= 0;
		return $self->pmdir_cb($input, $fl) if $self->can('pmdir_cb');
		my $eml = eml_from_path($input) or return
			$lei->qerr("# $input not readable");
		my $kw = PublicInbox::MdirReader::flags2kw($fl);
		$self->can('input_maildir_cb')->($input, $kw, $eml, $self);
		return;
	}
	my $devfd = $lei->path_to_fd($input) // return;
	if ($devfd >= 0) {
		$self->input_fh($ifmt, $lei->{$devfd}, $input, @args);
	} elsif (-f $input && $ifmt eq 'eml') {
		open my $fh, '<', $input or
					return $lei->fail("open($input): $!");
		$self->input_fh($ifmt, $fh, $input, @args);
	} elsif (-f _) {
		my $m = $lei->{opt}->{'lock'} //
			PublicInbox::MboxLock->defaults;
		my $mbl = PublicInbox::MboxLock->acq($input, 0, $m);
		my $zsfx = PublicInbox::MboxReader::zsfx($input);
		if ($zsfx) {
			my $in = delete $mbl->{fh};
			$mbl->{fh} =
			     PublicInbox::MboxReader::zsfxcat($in, $zsfx, $lei);
		}
		local $PublicInbox::DS::in_loop = 0 if $zsfx; # dwaitpid
		$self->input_fh($ifmt, $mbl->{fh}, $input, @args);
	} elsif (-d _ && (-d "$input/cur" || -d "$input/new")) {
		return $lei->fail(<<EOM) if $ifmt && $ifmt ne 'maildir';
$input appears to be a maildir, not $ifmt
EOM
		my $mdr = PublicInbox::MdirReader->new;
		if (my $pmd = $self->{pmd}) {
			$mdr->maildir_each_file($input,
						$pmd->can('each_mdir_fn'),
						$pmd, @args);
		} else {
			$mdr->maildir_each_eml($input,
						$self->can('input_maildir_cb'),
						$self, @args);
		}
	} elsif ($self->{missing_ok} && !-e $input) { # don't ->fail
		$self->folder_missing("$ifmt:$input");
	} else {
		$lei->fail("$ifmt_pfx$input unsupported (TODO)");
	}
}

# subclasses should overrride this (see LeiRefreshMailSync)
sub folder_missing { die "BUG: ->folder_missing undefined for $_[0]" }

sub bad_http ($$;$) {
	my ($lei, $url, $alt) = @_;
	my $x = $alt ? "did you mean <$alt>?" : 'download and import manually';
	$lei->fail("E: <$url> not recognized, $x");
}

sub prepare_http_input ($$$) {
	my ($self, $lei, $url) = @_;
	require URI;
	require PublicInbox::MboxReader;
	require PublicInbox::LeiCurl;
	require IO::Uncompress::Gunzip;
	$self->{curl} //= which('curl') or
				return $lei->fail("curl missing for <$url>");
	my $uri = URI->new($url);
	my $path = $uri->path;
	my %qf = $uri->query_form;
	my @curl_opt;
	if ($path =~ m!/(?:t\.mbox\.gz|all\.mbox\.gz)\z!) {
		# OK
	} elsif ($path =~ m!/raw\z!) {
		push @curl_opt, '--compressed';
	# convert search query to mboxrd request since they require POST
	# this is only intended for PublicInbox::WWW, and will false-positive
	# on many other search engines... oh well
	} elsif (defined $qf{'q'}) {
		$qf{x} = 'm';
		$uri->query_form(\%qf);
		push @curl_opt, '-d', '';
		$$uri ne $url and $lei->qerr(<<"");
# <$url> rewritten to <$$uri> with HTTP POST

	# try to provide hints for /$INBOX/$MSGID/T/ and /$INBOX/
	} elsif ($path =~ s!/[tT]/\z!/t.mbox.gz! ||
			$path =~ s!/t\.atom\z!/t.mbox.gz! ||
			$path =~ s!/([^/]+\@[^/]+)/\z!/$1/raw!) {
		$uri->path($path);
		return bad_http($lei, $url, $$uri);
	} else {
		return bad_http($lei, $url);
	}
	$self->{"-curl-$url"} = [ @curl_opt, $uri ]; # for handle_http_input
}

sub prepare_inputs { # returns undef on error
	my ($self, $lei, $inputs) = @_;
	my $in_fmt = $lei->{opt}->{'in-format'};
	my $sync = $lei->{opt}->{'mail-sync'} ? {} : undef; # using LeiMailSync
	my $may_sync = $sync || $self->{-mail_sync};
	if ($lei->{opt}->{stdin}) {
		@$inputs and return
			$lei->fail("--stdin and @$inputs do not mix");
		check_input_format($lei) or return;
		push @$inputs, '/dev/stdin';
		push @{$sync->{no}}, '/dev/stdin' if $sync;
	}
	my $net = $lei->{net}; # NetWriter may be created by l2m
	my (@f, @md);
	# e.g. Maildir:/home/user/Mail/ or imaps://example.com/INBOX
	for my $input (@$inputs) {
		my $input_path = $input;
		if ($input =~ m!\A(?:imaps?|nntps?|s?news)://!i) {
			require PublicInbox::NetReader;
			$net //= PublicInbox::NetReader->new;
			$net->add_url($input, $self->{-ls_ok});
			push @{$sync->{ok}}, $input if $sync;
		} elsif ($input_path =~ m!\Ahttps?://!i) { # mboxrd.gz
			# TODO: how would we detect r/w JMAP?
			push @{$sync->{no}}, $input if $sync;
			prepare_http_input($self, $lei, $input_path) or return;
		} elsif ($input_path =~ s/\A([a-z0-9]+)://is) {
			my $ifmt = lc $1;
			if (($in_fmt // $ifmt) ne $ifmt) {
				return $lei->fail(<<"");
--in-format=$in_fmt and `$ifmt:' conflict

			}
			if ($ifmt =~ /\A(?:maildir|mh)\z/i) {
				push @{$sync->{ok}}, $input if $sync;
			} else {
				push @{$sync->{no}}, $input if $sync;
			}
			my $devfd = $lei->path_to_fd($input_path) // return;
			if ($devfd >= 0 || (-f $input_path || -p _)) {
				require PublicInbox::MboxLock;
				require PublicInbox::MboxReader;
				PublicInbox::MboxReader->reads($ifmt) or return
					$lei->fail("$ifmt not supported");
			} elsif (-d $input_path) {
				$ifmt eq 'maildir' or return
					$lei->fail("$ifmt not supported");
				$may_sync and $input = 'maildir:'.
						$lei->abs_path($input_path);
				push @md, $input;
			} elsif ($self->{missing_ok} && !-e _) {
				# for "lei rm-watch" on missing Maildir
				$may_sync and $input = 'maildir:'.
						$lei->abs_path($input_path);
			} else {
				my $m = "Unable to handle $input";
				$input =~ /\A(?:L|kw):/ and
					$m .= ", did you mean +$input?";
				return $lei->fail($m);
			}
		} elsif ($input =~ /\.(?:eml|patch)\z/i && -f $input) {
			lc($in_fmt//'eml') eq 'eml' or return $lei->fail(<<"");
$input is `eml', not --in-format=$in_fmt

			push @{$sync->{no}}, $input if $sync;
		} elsif (-f $input && $input =~ m{\A(.+)/(new|cur)/([^/]+)\z}) {
			# single file in a Maildir
			my ($mdir, $nc, $bn) = ($1, $2, $3);
			my $other = $mdir . ($nc eq 'new' ? '/cur' : '/new');
			return $lei->fail(<<EOM) if !-d $other;
No `$other' directory for `$input'
EOM
			lc($in_fmt//'eml') eq 'eml' or return $lei->fail(<<"");
$input is `eml', not --in-format=$in_fmt

			if ($sync) {
				$input = $lei->abs_path($mdir) . "/$nc/$bn";
				push @{$sync->{ok}}, $input if $sync;
			}
			require PublicInbox::MdirReader;
		} else {
			my $devfd = $lei->path_to_fd($input) // return;
			if ($devfd >= 0 || -f $input || -p _) {
				push @{$sync->{no}}, $input if $sync;
				push @f, $input;
			} elsif (-d "$input/new" && -d "$input/cur") {
				if ($may_sync) {
					$input = 'maildir:'.
						$lei->abs_path($input);
					push @{$sync->{ok}}, $input if $sync;
				}
				push @md, $input;
			} elsif ($self->{missing_ok} && !-e $input) {
				# for lei rm-watch
				$may_sync and $input = 'maildir:'.
						$lei->abs_path($input);
			} else {
				return $lei->fail("Unable to handle $input")
			}
		}
	}
	if (@f) { check_input_format($lei, \@f) or return }
	if ($sync && $sync->{no}) {
		return $lei->fail(<<"") if !$sync->{ok};
--mail-sync specified but no inputs support it

		# non-fatal if some inputs support support sync
		$lei->err("# --mail-sync will only be used for @{$sync->{ok}}");
		$lei->err("# --mail-sync is not supported for: @{$sync->{no}}");
	}
	if ($net) {
		$net->{-can_die} = 1;
		if (my $err = $net->errors($lei)) {
			return $lei->fail($err);
		}
		$net->{quiet} = $lei->{opt}->{quiet};
		require PublicInbox::LeiAuth;
		$lei->{auth} //= PublicInbox::LeiAuth->new;
		$lei->{net} //= $net;
	}
	if (scalar(@md)) {
		require PublicInbox::MdirReader;
		if ($self->can('pmdir_cb')) {
			require PublicInbox::LeiPmdir;
			$self->{pmd} = PublicInbox::LeiPmdir->new($lei, $self);
		}

		# start watching Maildirs ASAP
		if ($may_sync && $lei->{sto}) {
			grep(!m!\Amaildir:/!i, @md) and die "BUG: @md (no pfx)";
			$lei->lms(1)->lms_write_prepare->add_folders(@md);
			$lei->refresh_watches;
		}
	}
	$self->{inputs} = $inputs;
}

sub process_inputs {
	my ($self) = @_;
	my $err;
	for my $input (@{$self->{inputs}}) {
		eval { $self->input_path_url($input) };
		next unless $@;
		$err = "$input: $@";
		last;
	}
	# always commit first, even on error partial work is acceptable for
	# lei <import|tag|convert>
	my $wait = $self->{lei}->{sto}->wq_do('done') if $self->{lei}->{sto};
	$self->{lei}->fail($err) if $err;
}

sub input_only_atfork_child {
	my ($self) = @_;
	my $lei = $self->{lei};
	$lei->_lei_atfork_child;
	PublicInbox::IPC::ipc_atfork_child($self);
	$lei->{auth}->do_auth_atfork($self) if $lei->{auth};
	undef;
}

# alias this as "net_merge_all_done" to use as an LeiAuth callback
sub input_only_net_merge_all_done {
	my ($self) = @_;
	$self->wq_io_do('process_inputs');
	$self->wq_close(1);
}

# like Getopt::Long, but for +kw:FOO and -kw:FOO to prepare
# for update_xvmd -> update_vmd
# returns something like { "+L" => [ @Labels ], ... }
sub vmd_mod_extract {
	my $argv = $_[-1];
	my $vmd_mod = {};
	my @new_argv;
	for my $x (@$argv) {
		if ($x =~ /\A(\+|\-)(kw|L):(.+)\z/) {
			my ($op, $pfx, $val) = ($1, $2, $3);
			if (my $err = $ERR{$pfx}->($val)) {
				push @{$vmd_mod->{err}}, $err;
			} else { # set "+kw", "+L", "-L", "-kw"
				push @{$vmd_mod->{$op.$pfx}}, $val;
			}
		} else {
			push @new_argv, $x;
		}
	}
	@$argv = @new_argv;
	$vmd_mod;
}

1;
