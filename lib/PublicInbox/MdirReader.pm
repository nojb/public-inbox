# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Maildirs for now, MH eventually
# ref: https://cr.yp.to/proto/maildir.html
#	https://wiki2.dovecot.org/MailboxFormat/Maildir
package PublicInbox::MdirReader;
use strict;
use v5.10.1;
use PublicInbox::InboxWritable qw(eml_from_path);
use Digest::SHA qw(sha256_hex);

# returns Maildir flags from a basename ('' for no flags, undef for invalid)
sub maildir_basename_flags {
	my (@f) = split(/:/, $_[0], -1);
	return if (scalar(@f) > 2 || substr($f[0], 0, 1) eq '.');
	$f[1] // return ''; # "new"
	$f[1] =~ /\A2,([A-Za-z]*)\z/ ? $1 : undef; # "cur"
}

# same as above, but for full path name
sub maildir_path_flags {
	my ($f) = @_;
	my $i = rindex($f, '/');
	$i >= 0 ? maildir_basename_flags(substr($f, $i + 1)) : undef;
}

sub shard_ok ($$$) {
	my ($bn, $mod, $shard) = @_;
	# can't get dirent.d_ino w/ pure Perl readdir, so we extract
	# the OID if it looks like one instead of doing stat(2)
	my $hex = $bn =~ m!\A([a-f0-9]{40,})! ? $1 : sha256_hex($bn);
	my $recno = hex(substr($hex, 0, 8));
	($recno % $mod) == $shard;
}

sub maildir_each_file {
	my ($self, $dir, $cb, @arg) = @_;
	$dir .= '/' unless substr($dir, -1) eq '/';
	my ($mod, $shard) = @{$self->{shard_info} // []};
	for my $d (qw(new/ cur/)) {
		my $pfx = $dir.$d;
		opendir my $dh, $pfx or next;
		while (defined(my $bn = readdir($dh))) {
			maildir_basename_flags($bn) // next;
			next if defined($mod) && !shard_ok($bn, $mod, $shard);
			$cb->($pfx.$bn, @arg);
		}
	}
}

my %c2kw = ('D' => 'draft', F => 'flagged', P => 'forwarded',
	R => 'answered', S => 'seen');

sub maildir_each_eml {
	my ($self, $dir, $cb, @arg) = @_;
	$dir .= '/' unless substr($dir, -1) eq '/';
	my ($mod, $shard) = @{$self->{shard_info} // []};
	my $pfx = $dir . 'new/';
	if (opendir(my $dh, $pfx)) {
		while (defined(my $bn = readdir($dh))) {
			next if substr($bn, 0, 1) eq '.';
			my @f = split(/:/, $bn, -1);

			# mbsync and offlineimap both use "2," in "new/"
			next if ($f[1] // '2,') ne '2,' || defined($f[2]);

			next if defined($mod) && !shard_ok($bn, $mod, $shard);
			my $f = $pfx.$bn;
			my $eml = eml_from_path($f) or next;
			$cb->($f, [], $eml, @arg);
		}
	}
	$pfx = $dir . 'cur/';
	opendir my $dh, $pfx or return;
	while (defined(my $bn = readdir($dh))) {
		my $fl = maildir_basename_flags($bn) // next;
		next if index($fl, 'T') >= 0;
		next if defined($mod) && !shard_ok($bn, $mod, $shard);
		my $f = $pfx.$bn;
		my $eml = eml_from_path($f) or next;
		my @kw = sort(map { $c2kw{$_} // () } split(//, $fl));
		$cb->($f, \@kw, $eml, @arg);
	}
}

sub new { bless {}, __PACKAGE__ }

sub flags2kw ($) {
	my @unknown;
	my %kw;
	for (split(//, $_[0])) {
		my $k = $c2kw{$_};
		if (defined($k)) {
			$kw{$k} = 1;
		} else {
			push @unknown, $_;
		}
	}
	(\%kw, \@unknown);
}

1;
