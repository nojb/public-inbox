#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use PublicInbox::TestCommon;
use PublicInbox::Config;
require_git 2.6;
require_mods(qw(DBD::SQLite));
require PublicInbox::SearchIdx;
use_ok 'PublicInbox::InboxIdle';
my ($tmpdir, $for_destroy) = tmpdir();

for my $V (1, 2) {
	my $inboxdir = "$tmpdir/$V";
	my $ibx = create_inbox "idle$V", tmpdir => $inboxdir, version => $V,
				indexlevel => 'basic', -no_gc => 1, sub {
		my ($im, $ibx) = @_; # capture
		$im->done;
		$ibx->init_inbox(0);
		$_[0] = undef;
		return if $V != 1;
		my $sidx = PublicInbox::SearchIdx->new($ibx, 1);
		$sidx->idx_acquire;
		$sidx->set_metadata_once;
		$sidx->idx_release; # allow watching on lockfile
	};
	my $obj = InboxIdleTestObj->new;
	my $pi_cfg = PublicInbox::Config->new(\<<EOF);
publicinbox.inbox-idle.inboxdir=$inboxdir
publicinbox.inbox-idle.indexlevel=basic
publicinbox.inbox-idle.address=$ibx->{-primary_address}
EOF
	my $ident = 'whatever';
	$pi_cfg->each_inbox(sub { shift->subscribe_unlock($ident, $obj) });
	my $ii = PublicInbox::InboxIdle->new($pi_cfg);
	ok($ii, 'InboxIdle created');
	SKIP: {
		skip('inotify or kqueue missing', 1) unless $ii->{sock};
		ok(fileno($ii->{sock}) >= 0, 'fileno() gave valid FD');
	}
	my $im = $ibx->importer(0);
	ok($im->add(eml_load('t/utf8.eml')), "$V added");
	$im->done;
	$ii->event_step;
	is(scalar @{$obj->{called}}, 1, 'called on unlock');
	$pi_cfg->each_inbox(sub { shift->unsubscribe_unlock($ident) });
	ok($im->add(eml_load('t/data/0001.patch')), "$V added #2");
	$im->done;
	$ii->event_step;
	is(scalar @{$obj->{called}}, 1, 'not called when unsubbed');
	$ii->close;
}

done_testing;

package InboxIdleTestObj;
use strict;

sub new { bless {}, shift }

sub on_inbox_unlock {
	my ($self, $ibx) = @_;
	push @{$self->{called}}, $ibx;
}
