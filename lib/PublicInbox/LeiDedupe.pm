# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
package PublicInbox::LeiDedupe;
use strict;
use v5.10.1;
use PublicInbox::SharedKV;
use PublicInbox::ContentHash qw(content_hash);

# n.b. mutt sets most of these headers not sure about Bytes
our @OID_IGNORE = qw(Status X-Status Content-Length Lines Bytes);

# best-effort regeneration of OID when augmenting existing results
sub _regen_oid ($) {
	my ($eml) = @_;
	my @stash; # stash away headers we shouldn't have in git
	for my $k (@OID_IGNORE) {
		my @v = $eml->header_raw($k) or next;
		push @stash, [ $k, \@v ];
		$eml->header_set($k); # restore below
	}
	my $dig = Digest::SHA->new(1); # XXX SHA256 later
	my $buf = $eml->as_string;
	$dig->add('blob '.length($buf)."\0");
	$dig->add($buf);
	undef $buf;

	for my $kv (@stash) { # restore stashed headers
		my ($k, @v) = @$kv;
		$eml->header_set($k, @v);
	}
	$dig->digest;
}

sub _oidbin ($) { defined($_[0]) ? pack('H*', $_[0]) : undef }

sub smsg_hash ($) {
	my ($smsg) = @_;
	my $dig = Digest::SHA->new(256);
	my $x = join("\0", @$smsg{qw(from to cc ds subject references mid)});
	utf8::encode($x);
	$dig->add($x);
	$dig->digest;
}

# the paranoid option
sub dedupe_oid () {
	my $skv = PublicInbox::SharedKV->new;
	($skv, sub { # may be called in a child process
		my ($eml, $oid) = @_;
		$skv->set_maybe(_oidbin($oid) // _regen_oid($eml), '');
	}, sub {
		my ($smsg) = @_;
		$skv->set_maybe(_oidbin($smsg->{blob}), '');
	});
}

# dangerous if there's duplicate messages with different Message-IDs
sub dedupe_mid () {
	my $skv = PublicInbox::SharedKV->new;
	($skv, sub { # may be called in a child process
		my ($eml, $oid) = @_;
		# TODO: lei will support non-public messages w/o Message-ID
		my $mid = $eml->header_raw('Message-ID') // _oidbin($oid) //
			content_hash($eml);
		$skv->set_maybe($mid, '');
	}, sub {
		my ($smsg) = @_;
		my $mid = $smsg->{mid};
		$mid = undef if $mid eq '';
		$mid //= smsg_hash($smsg) // _oidbin($smsg->{blob});
		$skv->set_maybe($mid, '');
	});
}

# our default deduplication strategy (used by v2, also)
sub dedupe_content () {
	my $skv = PublicInbox::SharedKV->new;
	($skv, sub { # may be called in a child process
		my ($eml) = @_; # oid = $_[1], ignored
		$skv->set_maybe(content_hash($eml), '');
	}, sub {
		my ($smsg) = @_;
		$skv->set_maybe(smsg_hash($smsg), '');
	});
}

# no deduplication at all
sub true { 1 }
sub dedupe_none () { (undef, \&true, \&true) }

sub new {
	my ($cls, $lei, $dst) = @_;
	my $dd = $lei->{opt}->{dedupe} // 'content';

	# allow "none" to bypass Eml->new if writing to directory:
	return if ($dd eq 'none' && substr($dst // '', -1) eq '/');

	my $dd_new = $cls->can("dedupe_$dd") //
			die "unsupported dedupe strategy: $dd\n";
	bless [ $dd_new->() ], $cls; # [ $skv, $cb ]
}

# returns true on unseen messages according to the deduplication strategy,
# returns false if seen
sub is_dup {
	my ($self, $eml, $oid) = @_;
	!$self->[1]->($eml, $oid);
}

sub is_smsg_dup {
	my ($self, $smsg) = @_;
	!$self->[2]->($smsg);
}

sub prepare_dedupe {
	my ($self) = @_;
	my $skv = $self->[0];
	$skv ? $skv->dbh : undef;
}

sub pause_dedupe {
	my ($self) = @_;
	my $skv = $self->[0];
	delete($skv->{dbh}) if $skv;
}

1;
