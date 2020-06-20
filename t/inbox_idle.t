#!perl -w
# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use Test::More;
use PublicInbox::TestCommon;
use PublicInbox::Config;
require_git 2.6;
require_mods(qw(DBD::SQLite));
require PublicInbox::SearchIdx;
use_ok 'PublicInbox::InboxIdle';
use PublicInbox::InboxWritable;
my ($tmpdir, $for_destroy) = tmpdir();

for my $V (1, 2) {
	my $inboxdir = "$tmpdir/$V";
	mkdir $inboxdir or BAIL_OUT("mkdir: $!");
	my %opt = (
		inboxdir => $inboxdir,
		name => 'inbox-idle',
		version => $V,
		-primary_address => 'test@example.com',
		indexlevel => 'basic',
	);
	my $ibx = PublicInbox::Inbox->new({ %opt });
	$ibx = PublicInbox::InboxWritable->new($ibx);
	my $obj = InboxIdleTestObj->new;
	$ibx->init_inbox(0);
	my $im = $ibx->importer(0);
	if ($V == 1) {
		my $sidx = PublicInbox::SearchIdx->new($ibx, 1);
		$sidx->_xdb_acquire;
		$sidx->set_indexlevel;
		$sidx->_xdb_release; # allow watching on lockfile
	}
	my $pi_config = PublicInbox::Config->new(\<<EOF);
publicinbox.inbox-idle.inboxdir=$inboxdir
publicinbox.inbox-idle.indexlevel=basic
publicinbox.inbox-idle.address=test\@example.com
EOF
	my $ident = 'whatever';
	$pi_config->each_inbox(sub { shift->subscribe_unlock($ident, $obj) });
	my $ii = PublicInbox::InboxIdle->new($pi_config);
	ok($ii, 'InboxIdle created');
	SKIP: {
		skip('inotify or kqueue missing', 1) unless $ii->{sock};
		ok(fileno($ii->{sock}) >= 0, 'fileno() gave valid FD');
	}
	ok($im->add(eml_load('t/utf8.eml')), "$V added");
	$im->done;
	PublicInbox::SearchIdx->new($ibx)->index_sync if $V == 1;
	$ii->event_step;
	is(scalar @{$obj->{called}}, 1, 'called on unlock');
	$pi_config->each_inbox(sub { shift->unsubscribe_unlock($ident) });
	ok($im->add(eml_load('t/data/0001.patch')), "$V added #2");
	$im->done;
	PublicInbox::SearchIdx->new($ibx)->index_sync if $V == 1;
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
