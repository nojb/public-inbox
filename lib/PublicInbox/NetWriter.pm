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

sub imap_append {
	my ($mic, $folder, $bref, $smsg, $eml) = @_;
	$bref //= \($eml->as_string);
	$smsg //= bless {}, 'PublicInbox::Smsg';
	bless($smsg, 'PublicInbox::Smsg') if ref($smsg) eq 'HASH';
	$smsg->{ts} //= msg_timestamp($eml // PublicInbox::Eml->new($$bref));
	my @f = map { $IMAPkw2flags{$_} } @{$smsg->{kw}};
	$mic->append_string($folder, $$bref, "@f", $smsg->internaldate) or
		die "APPEND $folder: $@";
}

sub imap_delete_all {
	my ($self, $url) = @_;
	my $uri = PublicInbox::URIimap->new($url);
	my $sec = $self->can('uri_section')->($uri);
	local $0 = $uri->mailbox." $sec";
	my $mic = $self->mic_get($uri) or die "E: not connected: $@";
	$mic->select($uri->mailbox) or return; # non-existent
	if ($mic->delete_message('1:*')) {
		$mic->expunge;
	}
}

1;
