# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# common writer code for IMAP (and later, JMAP)
package PublicInbox::NetWriter;
use strict;
use v5.10.1;
use parent qw(PublicInbox::NetReader);
use PublicInbox::Smsg;
use PublicInbox::MsgTime qw(msg_timestamp);

my %IMAPkw2flags;
@IMAPkw2flags{values %PublicInbox::NetReader::IMAPflags2kw} =
				keys %PublicInbox::NetReader::IMAPflags2kw;

sub kw2flags ($) { join(' ', map { $IMAPkw2flags{$_} } @{$_[0]}) }

sub imap_append {
	my ($mic, $folder, $bref, $smsg, $eml) = @_;
	$bref //= \($eml->as_string);
	$smsg //= bless {}, 'PublicInbox::Smsg';
	bless($smsg, 'PublicInbox::Smsg') if ref($smsg) eq 'HASH';
	$smsg->{ts} //= msg_timestamp($eml // PublicInbox::Eml->new($$bref));
	my $f = kw2flags($smsg->{kw});
	$mic->append_string($folder, $$bref, $f, $smsg->internaldate) or
		die "APPEND $folder: $@";
}

sub folder_select { 'select' } # for PublicInbox::NetReader

sub imap_delete_all {
	my ($self, $uri) = @_;
	my $mic = $self->mic_for_folder($uri) or return;
	my $sec = $self->can('uri_section')->($uri);
	local $0 = $uri->mailbox." $sec";
	if ($mic->delete_message('1:*')) {
		$mic->expunge;
	}
}

sub imap_delete_1 {
	my ($self, $uri, $uid, $delete_mic) = @_;
	$$delete_mic //= $self->mic_for_folder($uri) or return;
	$$delete_mic->delete_message($uid);
}

sub imap_add_kw {
	my ($self, $mic, $uid, $kw) = @_;
	$mic->store($uid, '+FLAGS.SILENT', '('.kw2flags($kw).')');
	$mic; # caller must ->expunge
}

sub imap_set_kw {
	my ($self, $mic, $uid, $kw) = @_;
	$mic->store($uid, 'FLAGS.SILENT', '('.kw2flags($kw).')');
	$mic; # caller must ->expunge
}

sub can_store_flags {
	my ($self, $mic) = @_;
	for ($mic->Results) {
		/^\* OK \[PERMANENTFLAGS \(([^\)]*)\)\].*/ and
			return $self->can('perm_fl_ok')->($1);
	}
	undef;
}

1;
