# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# The "lei mail-diff" sub-command, diffs input contents against
# the first message of input
package PublicInbox::LeiMailDiff;
use strict;
use v5.10.1;
use parent qw(PublicInbox::IPC PublicInbox::LeiInput);
use File::Temp 0.19 (); # 0.19 for ->newdir
use PublicInbox::Spawn qw(spawn which);
use PublicInbox::MsgIter qw(msg_part_text);
use File::Path qw(remove_tree);
use PublicInbox::ContentHash qw(content_digest);
require PublicInbox::LeiRediff;
use Data::Dumper ();

sub write_part { # Eml->each_part callback
	my ($ary, $self) = @_;
	my ($part, $depth, $idx) = @$ary;
	if ($idx ne '1' || $self->{lei}->{opt}->{'raw-header'}) {
		open my $fh, '>', "$self->{curdir}/$idx.hdr" or die "open: $!";
		print $fh ${$part->{hdr}} or die "print $!";
		close $fh or die "close $!";
	}
	my $ct = $part->content_type || 'text/plain';
	my ($s, $err) = msg_part_text($part, $ct);
	my $sfx = defined($s) ? 'txt' : 'bin';
	open my $fh, '>', "$self->{curdir}/$idx.$sfx" or die "open: $!";
	print $fh ($s // $part->body) or die "print $!";
	close $fh or die "close $!";
}

sub dump_eml ($$$) {
	my ($self, $dir, $eml) = @_;
	local $self->{curdir} = $dir;
	mkdir $dir or die "mkdir($dir): $!";
	$eml->each_part(\&write_part, $self);

	open my $fh, '>', "$dir/content_digest" or die "open: $!";
	my $dig = PublicInbox::ContentDigestDbg->new($fh);
	local $Data::Dumper::Useqq = 1;
	local $Data::Dumper::Terse = 1;
	content_digest($eml, $dig);
	print $fh "\n", $dig->hexdigest, "\n" or die "print $!";
	close $fh or die "close: $!";
}

sub prep_a ($$) {
	my ($self, $eml) = @_;
	$self->{tmp} = File::Temp->newdir('lei-mail-diff-XXXX', TMPDIR => 1);
	dump_eml($self, "$self->{tmp}/a", $eml);
}

sub diff_a ($$) {
	my ($self, $eml) = @_;
	++$self->{nr};
	my $dir = "$self->{tmp}/N$self->{nr}";
	dump_eml($self, $dir, $eml);
	my $cmd = [ qw(git diff --no-index) ];
	my $lei = $self->{lei};
	PublicInbox::LeiRediff::_lei_diff_prepare($lei, $cmd);
	push @$cmd, qw(-- a), "N$self->{nr}";
	my $rdr = { -C => "$self->{tmp}" };
	@$rdr{1, 2} = @$lei{1, 2};
	my $pid = spawn($cmd, $lei->{env}, $rdr);
	waitpid($pid, 0);
	$lei->child_error($?) if $?; # for git diff --exit-code
	File::Path::remove_tree($self->{curdir});
}

sub input_eml_cb { # used by PublicInbox::LeiInput::input_fh
	my ($self, $eml) = @_;
	$self->{tmp} ? diff_a($self, $eml) : prep_a($self, $eml);
}

sub lei_mail_diff {
	my ($lei, @argv) = @_;
	$lei->{opt}->{'in-format'} //= 'eml' if !grep(/\A[a-z0-9]+:/i, @argv);
	my $self = bless {}, __PACKAGE__;
	$self->prepare_inputs($lei, \@argv) or return;
	my $isatty = -t $lei->{1};
	$lei->{opt}->{color} //= $isatty;
	$lei->start_pager if $isatty;
	my $ops = {};
	$lei->{auth}->op_merge($ops, $self, $lei) if $lei->{auth};
	(my $op_c, $ops) = $lei->workers_start($self, 1, $ops);
	$lei->{wq1} = $self;
	$lei->{-err_type} = 'non-fatal';
	net_merge_all_done($self) unless $lei->{auth};
	$lei->wait_wq_events($op_c, $ops);
}

no warnings 'once';
*net_merge_all_done = \&PublicInbox::LeiInput::input_only_net_merge_all_done;

package PublicInbox::ContentDigestDbg; # cf. PublicInbox::ContentDigest
use strict;
use v5.10.1;
use Data::Dumper;

sub new { bless { dig => Digest::SHA->new(256), fh => $_[1] }, __PACKAGE__ }

sub add {
	$_[0]->{dig}->add($_[1]);
	print { $_[0]->{fh} } Dumper([split(/^/sm, $_[1])]) or die "print $!";
}

sub hexdigest { $_[0]->{dig}->hexdigest; }

1;
