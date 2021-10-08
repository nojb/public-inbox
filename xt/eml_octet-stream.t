#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
use PublicInbox::Git;
use PublicInbox::Eml;
use PublicInbox::MsgIter qw(msg_part_text);
use PublicInbox::LeiToMail;
my $eml2mboxcl2 = PublicInbox::LeiToMail->can('eml2mboxcl2');
my $git_dir = $ENV{GIANT_GIT_DIR};
plan 'skip_all' => "GIANT_GIT_DIR not defined for $0" unless defined($git_dir);
use Data::Dumper;
$Data::Dumper::Useqq = 1;
my $mboxfh;
if (my $out = $ENV{DEBUG_MBOXCL2}) {
	BAIL_OUT("$out exists") if -s $out;
	open $mboxfh, '>', $out or BAIL_OUT "open $out: $!";
} else {
	diag "DEBUG_MBOXCL2 unset, not saving debug output";
}

my $git = PublicInbox::Git->new($git_dir);
my @cat = qw(cat-file --buffer --batch-check --batch-all-objects);
if (require_git(2.19, 1)) {
	push @cat, '--unordered';
} else {
	warn "git <2.19, cat-file lacks --unordered, locality suffers\n";
}
my ($errs, $ok, $tot);
$errs = $ok = $tot = 0;
my $ep = sub { # eml->each_part callback
	my ($part, $level, @ex) = @{$_[0]};
	++$tot;
	my $ct = $part->content_type // return;
	$ct =~ m!\bapplication/octet-stream\b!i or return;
	my ($s, $err) = msg_part_text($part, $ct);
	if (defined $s) {
		++$ok;
	} else {
		warn "binary $err\n";
		++$errs;
		my $x = eval { $part->body };
		if ($@) {
			warn "decode totally failed: $@";
		} else {
			my ($bad) = ($x =~ m/([\p{XPosixPrint}\s]{0,10}
						[^\p{XPosixPrint}\s]+
						[\p{XPosixPrint}\s]{0,10})/sx);
			warn Dumper([$bad]);
		}

		push @{$_[1]}, $err; # $fail
	}
};

my $cb = sub {
	my ($bref, $oid) = @_;
	my $eml = PublicInbox::Eml->new($bref);
	local $SIG{__WARN__} = sub { diag("$oid ", @_) };
	$eml->each_part($ep, my $fail = []);
	if (@$fail && $mboxfh) {
		diag "@$fail";
		print $mboxfh ${$eml2mboxcl2->($eml, { blob => $oid })} or
			BAIL_OUT "print: $!";
	}
};
my $cat = $git->popen(@cat);
while (<$cat>) {
	my ($oid, $type, $size) = split(/ /);
	$git->cat_async($oid, $cb) if $size && $type eq 'blob';
}
$git->async_wait_all;
note "$errs errors";
note "$ok/$tot messages had text as application/octet-stream";
ok 1;

done_testing;
