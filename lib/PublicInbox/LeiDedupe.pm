# Copyright (C) 2020 all contributors <meta@public-inbox.org>
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

# the paranoid option
sub dedupe_oid () {
	my $skv = PublicInbox::SharedKV->new;
	($skv, sub { # may be called in a child process
		my ($eml, $oid) = @_;
		$skv->set_maybe(_oidbin($oid) // _regen_oid($eml), '');
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
	});
}

# our default deduplication strategy (used by v2, also)
sub dedupe_content () {
	my $skv = PublicInbox::SharedKV->new;
	($skv, sub { # may be called in a child process
		my ($eml) = @_; # oid = $_[1], ignored
		$skv->set_maybe(content_hash($eml), '');
	});
}

# no deduplication at all
sub dedupe_none () { (undef, sub { 1 }) }

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
