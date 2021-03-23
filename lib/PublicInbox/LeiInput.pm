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
	require PublicInbox::MboxLock if $files;
	require PublicInbox::MboxReader;
	return 1 if $fmt eq 'eml';
	# XXX: should this handle {gz,bz2,xz}? that's currently in LeiToMail
	PublicInbox::MboxReader->reads($fmt) or
		return $lei->fail("--$opt_key=$fmt unrecognized");
	1;
}

# import a single file handle of $name
# Subclass must define ->eml_cb and ->mbox_cb
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
		$self->eml_cb(PublicInbox::Eml->new(\$buf), @args);
	} else {
		# prepare_inputs already validated $ifmt
		my $cb = PublicInbox::MboxReader->reads($ifmt) //
				die "BUG: bad fmt=$ifmt";
		$cb->(undef, $fh, $self->can('mbox_cb'), $self, @args);
	}
}

sub prepare_inputs { # returns undef on error
	my ($self, $lei, $inputs) = @_;
	my $in_fmt = $lei->{opt}->{'in-format'};
	if ($lei->{opt}->{stdin}) {
		@$inputs and return
			$lei->fail("--stdin and @$inputs do not mix");
		check_input_format($lei) or return;
		$self->{0} = $lei->{0};
	}
	my $net = $lei->{net}; # NetWriter may be created by l2m
	my $fmt = $lei->{opt}->{'in-format'};
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
			if (-f $input_path) {
				require PublicInbox::MboxLock;
				require PublicInbox::MboxReader;
				PublicInbox::MboxReader->reads($ifmt) or return
					$lei->fail("$ifmt not supported");
			} elsif (-d _) {
				require PublicInbox::MdirReader;
				$ifmt eq 'maildir' or return
					$lei->fail("$ifmt not supported");
			} else {
				return $lei->fail("Unable to handle $input");
			}
		} elsif (-f $input) { push @f, $input }
		elsif (-d _) { push @d, $input }
		else { return $lei->fail("Unable to handle $input") }
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
