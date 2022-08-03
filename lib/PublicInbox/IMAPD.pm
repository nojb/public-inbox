# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# represents an IMAPD, see script/public-inbox-imapd for how it is used
package PublicInbox::IMAPD;
use strict;
use v5.10.1;
use PublicInbox::Config;
use PublicInbox::InboxIdle;
use PublicInbox::IMAP;
use PublicInbox::DummyInbox;
my $dummy = bless { uidvalidity => 0 }, 'PublicInbox::DummyInbox';

sub new {
	my ($class) = @_;
	bless {
		# mailboxes => {},
		err => \*STDERR,
		out => \*STDOUT,
		# ssl_ctx_opt => { SSL_cert_file => ..., SSL_key_file => ... }
		# pi_cfg => PublicInbox::Config
		# idler => PublicInbox::InboxIdle
	}, $class;
}

sub imapd_refresh_ibx { # pi_cfg->each_inbox cb
	my ($ibx, $imapd, $cache, $dummies) = @_;
	my $ngname = $ibx->{newsgroup} // return;

	# We require lower-case since IMAP mailbox names are
	# case-insensitive (but -nntpd matches INN in being
	# case-sensitive)
	if ($ngname =~ m![^a-z0-9/_\.\-\~\@\+\=:]! ||
			# don't confuse with 50K slices
			$ngname =~ /\.[0-9]+\z/) {
		warn "mailbox name invalid: newsgroup=`$ngname'\n";
		return;
	}
	my $ce = $cache->{$ngname};
	%$ibx = (%$ibx, %$ce) if $ce;
	# only valid if msgmap and over works:
	if (defined($ibx->uidvalidity)) {
		# fill ->{mailboxes}:
		PublicInbox::IMAP::ensure_slices_exist($imapd, $ibx);
		# preload to avoid fragmentation:
		$ibx->description;
		$ibx->base_url;
		# ensure dummies are selectable:
		do {
			$dummies->{$ngname} = $dummy;
		} while ($ngname =~ s/\.[^\.]+\z//);
	}
	delete @$ibx{qw(mm over)};
}

sub refresh_groups {
	my ($self, $sig) = @_;
	my $pi_cfg = PublicInbox::Config->new;
	my $mailboxes = $self->{mailboxes} = {};
	my $cache = eval { $pi_cfg->ALL->misc->nntpd_cache_load } // {};
	my $dummies = {};
	$pi_cfg->each_inbox(\&imapd_refresh_ibx, $self, $cache, $dummies);
	%$dummies = (%$dummies, %$mailboxes);
	$mailboxes = $self->{mailboxes} = $dummies;
	@{$self->{mailboxlist}} = map { $_->[2] }
		sort { $a->[0] cmp $b->[0] || $a->[1] <=> $b->[1] }
		map {
			my $u = $_; # capitalize "INBOX" for user-familiarity
			$u =~ s/\Ainbox(\.|\z)/INBOX$1/i;
			if ($mailboxes->{$_} == $dummy) {
				[ $u, -1,
				  qq[* LIST (\\HasChildren) "." $u\r\n]]
			} else {
				$u =~ /\A(.+)\.([0-9]+)\z/ or
					die "BUG: `$u' has no slice digit(s)";
				[ $1, $2 + 0,
				  qq[* LIST (\\HasNoChildren) "." $u\r\n] ]
			}
		} keys %$mailboxes;
	$self->{pi_cfg} = $pi_cfg;
	if (my $idler = $self->{idler}) {
		$idler->refresh($pi_cfg);
	}
}

sub idler_start {
	$_[0]->{idler} //= PublicInbox::InboxIdle->new($_[0]->{pi_cfg});
}

1;
