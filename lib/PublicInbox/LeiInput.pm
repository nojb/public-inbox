# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# parent class for LeiImport, LeiConvert
package PublicInbox::LeiInput;
use strict;
use v5.10.1;

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
	# XXX: should this handle {gz,bz2,xz}? that's currently in LeiToMail
	PublicInbox::MboxReader->reads($fmt) or
		return $lei->fail("--$opt_key=$fmt unrecognized");
	1;
}

# import a single file handle of $name
# Subclass must define ->input_eml_cb and ->input_mbox_cb
sub input_fh {
	my ($self, $ifmt, $fh, $name, @args) = @_;
	if ($ifmt eq 'eml') {
		my $buf = do { local $/; <$fh> } //
			return $self->{lei}->child_error(1 << 8, <<"");
error reading $name: $!

		# mutt pipes single RFC822 messages with a "From " line,
		# but no Content-Length or "From " escaping.
		# "git format-patch" also generates such files by default.
		$buf =~ s/\A[\r\n]*From [^\r\n]*\r?\n//s;
		$self->input_eml_cb(PublicInbox::Eml->new(\$buf), @args);
	} else {
		# prepare_inputs already validated $ifmt
		my $cb = PublicInbox::MboxReader->reads($ifmt) //
				die "BUG: bad fmt=$ifmt";
		$cb->(undef, $fh, $self->can('input_mbox_cb'), $self, @args);
	}
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
	}
	if ($input =~ s!\A([a-z0-9]+):!!i) {
		$ifmt = lc($1);
	} elsif ($input =~ /\.(?:patch|eml)\z/i) {
		$ifmt = 'eml';
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
		$self->input_fh($ifmt, $mbl->{fh}, $input, @args);
	} elsif (-d _ && (-d "$input/cur" || -d "$input/new")) {
		return $lei->fail(<<EOM) if $ifmt && $ifmt ne 'maildir';
$input appears to a be a maildir, not $ifmt
EOM
		PublicInbox::MdirReader::maildir_each_eml($input,
					$self->can('input_maildir_cb'),
					$self, @args);
	} else {
		$lei->fail("$input unsupported (TODO)");
	}
}

sub prepare_inputs { # returns undef on error
	my ($self, $lei, $inputs) = @_;
	my $in_fmt = $lei->{opt}->{'in-format'};
	if ($lei->{opt}->{stdin}) {
		@$inputs and return
			$lei->fail("--stdin and @$inputs do not mix");
		check_input_format($lei) or return;
		push @$inputs, '/dev/stdin';
	}
	my $net = $lei->{net}; # NetWriter may be created by l2m
	my (@f, @d);
	# e.g. Maildir:/home/user/Mail/ or imaps://example.com/INBOX
	for my $input (@$inputs) {
		my $input_path = $input;
		if ($input =~ m!\A(?:imaps?|nntps?|s?news)://!i) {
			require PublicInbox::NetReader;
			$net //= PublicInbox::NetReader->new;
			$net->add_url($input);
		} elsif ($input_path =~ s/\A([a-z0-9]+)://is) {
			my $ifmt = lc $1;
			if (($in_fmt // $ifmt) ne $ifmt) {
				return $lei->fail(<<"");
--in-format=$in_fmt and `$ifmt:' conflict

			}
			my $devfd = $lei->path_to_fd($input_path) // return;
			if ($devfd >= 0 || (-f $input_path || -p _)) {
				require PublicInbox::MboxLock;
				require PublicInbox::MboxReader;
				PublicInbox::MboxReader->reads($ifmt) or return
					$lei->fail("$ifmt not supported");
			} elsif (-d $input_path) {
				require PublicInbox::MdirReader;
				$ifmt eq 'maildir' or return
					$lei->fail("$ifmt not supported");
			} else {
				return $lei->fail("Unable to handle $input");
			}
		} elsif ($input =~ /\.(eml|patch)\z/i && -f $input) {
			lc($in_fmt//'eml') eq 'eml' or return $lei->fail(<<"");
$input is `eml', not --in-format=$in_fmt

			require PublicInbox::Eml;
		} else {
			my $devfd = $lei->path_to_fd($input) // return;
			if ($devfd >= 0 || -f $input || -p _) {
				push @f, $input
			} elsif (-d $input) {
				push @d, $input
			} else {
				return $lei->fail("Unable to handle $input")
			}
		}
	}
	if (@f) { check_input_format($lei, \@f) or return }
	if (@d) { # TODO: check for MH vs Maildir, here
		require PublicInbox::MdirReader;
	}
	if ($net) {
		if (my $err = $net->errors) {
			return $lei->fail($err);
		}
		$net->{quiet} = $lei->{opt}->{quiet};
		require PublicInbox::LeiAuth;
		$lei->{auth} //= PublicInbox::LeiAuth->new;
		$lei->{net} //= $net;
	}
	$self->{inputs} = $inputs;
}

sub input_only_atfork_child {
	my ($self) = @_;
	my $lei = $self->{lei};
	$lei->_lei_atfork_child;
	PublicInbox::IPC::ipc_atfork_child($self);
	$lei->{auth}->do_auth_atfork($self) if $lei->{auth};
	undef;
}

1;
