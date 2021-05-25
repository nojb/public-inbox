# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# "lei inspect" general purpose inspector for stuff in SQLite and
# Xapian.  Will eventually be useful with plain public-inboxes,
# not just lei/store.  This is totally half-baked at the moment
# but useful for testing.
package PublicInbox::LeiInspect;
use strict;
use v5.10.1;
use PublicInbox::Config;

sub inspect_blob ($$) {
	my ($lei, $oidhex) = @_;
	my $ent = {};
	if (my $lse = $lei->{lse}) {
		my @docids = $lse ? $lse->over->blob_exists($oidhex) : ();
		$ent->{'lei/store'} = \@docids if @docids;
		my $lms = $lse->lms;
		if (my $loc = $lms ? $lms->locations_for($oidhex) : undef) {
			$ent->{'mail-sync'} = $loc;
		}
	}
	$ent;
}

sub inspect_sync_folder ($$) {
	my ($lei, $folder) = @_;
	my $ent = {};
	my $lse = $lei->{lse} or return $ent;
	my $lms = $lse->lms or return $ent;
	my $folders = [ $folder ];
	my $err = $lms->arg2folder($lei, $folders);
	if ($err) {
		if ($err->{fail}) {
			$lei->qerr("# no folders match $folder (non-fatal)");
			@$folders = ();
		}
		$lei->qerr(@{$err->{qerr}}) if $err->{qerr};
	}
	for my $f (@$folders) {
		$ent->{$f} = $lms->location_stats($f); # may be undef
	}
	$ent
}

sub inspect1 ($$$) {
	my ($lei, $item, $more) = @_;
	my $ent;
	if ($item =~ /\Ablob:(.+)/) {
		$ent = inspect_blob($lei, $1);
	} elsif ($item =~ m!\Aimaps?://!i ||
			$item =~ m!\A(?:maildir|mh):!i || -d $item) {
		$ent = inspect_sync_folder($lei, $item);
	} else { # TODO: more things
		return $lei->fail("$item not understood");
	}
	$lei->out($lei->{json}->encode($ent));
	$lei->out(',') if $more;
	1;
}

sub lei_inspect {
	my ($lei, @argv) = @_;
	$lei->{1}->autoflush(0);
	my $multi = scalar(@argv) > 1;
	$lei->out('[') if $multi;
	$lei->{json} = ref(PublicInbox::Config::json())->new->utf8->canonical;
	$lei->{lse} = ($lei->{opt}->{external} // 1) ? do {
		my $sto = $lei->_lei_store;
		$sto ? $sto->search : undef;
	} : undef;
	if ($lei->{opt}->{pretty} || -t $lei->{1}) {
		$lei->{json}->pretty(1)->indent(2);
	}
	while (defined(my $x = shift @argv)) {
		inspect1($lei, $x, scalar(@argv)) or return;
	}
	$lei->out(']') if $multi;
}

1;
