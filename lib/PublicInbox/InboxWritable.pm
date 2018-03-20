# Copyright (C) 2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Extends read-only Inbox for writing
package PublicInbox::InboxWritable;
use strict;
use warnings;
use base qw(PublicInbox::Inbox);
use PublicInbox::Import;
use PublicInbox::Filter::Base;
*REJECT = *PublicInbox::Filter::Base::REJECT;

sub new {
	my ($class, $ibx) = @_;
	bless $ibx, $class;
}

sub importer {
	my ($self, $parallel) = @_;
	$self->{-importer} ||= eval {
		my $v = $self->{version} || 1;
		if ($v == 2) {
			eval { require PublicInbox::V2Writable };
			die "v2 not supported: $@\n" if $@;
			my $v2w = PublicInbox::V2Writable->new($self);
			$v2w->{parallel} = $parallel;
			$v2w;
		} elsif ($v == 1) {
			my $git = $self->git;
			my $name = $self->{name};
			my $addr = $self->{-primary_address};
			PublicInbox::Import->new($git, $name, $addr, $self);
		} else {
			die "unsupported inbox version: $v\n";
		}
	}
}

sub filter {
	my ($self) = @_;
	my $f = $self->{filter};
	if ($f && $f =~ /::/) {
		my @args = (-inbox => $self);
		# basic line splitting, only
		# Perhaps we can have proper quote splitting one day...
		($f, @args) = split(/\s+/, $f) if $f =~ /\s+/;

		eval "require $f";
		if ($@) {
			warn $@;
		} else {
			# e.g: PublicInbox::Filter::Vger->new(@args)
			return $f->new(@args);
		}
	}
	undef;
}

sub is_maildir_basename ($) {
	my ($bn) = @_;
	return 0 if $bn !~ /\A[a-zA-Z0-9][\-\w:,=\.]+\z/;
	if ($bn =~ /:2,([A-Z]+)\z/i) {
		my $flags = $1;
		return 0 if $flags =~ /[DT]/; # no [D]rafts or [T]rashed mail
	}
	1;
}

sub is_maildir_path ($) {
	my ($path) = @_;
	my @p = split(m!/+!, $path);
	(is_maildir_basename($p[-1]) && -f $path) ? 1 : 0;
}

sub maildir_path_load ($) {
	my ($path) = @_;
	if (open my $fh, '<', $path) {
		local $/;
		my $str = <$fh>;
		$str or return;
		return PublicInbox::MIME->new(\$str);
	} elsif ($!{ENOENT}) {
		# common with Maildir
		return;
	} else {
		warn "failed to open $path: $!\n";
		return;
	}
}

sub import_maildir {
	my ($self, $dir) = @_;
	my $im = $self->importer(1);
	my $filter = $self->filter;
	foreach my $sub (qw(cur new tmp)) {
		-d "$dir/$sub" or die "$dir is not a Maildir (missing $sub)\n";
	}
	foreach my $sub (qw(cur new)) {
		opendir my $dh, "$dir/$sub" or die "opendir $dir/$sub: $!\n";
		while (defined(my $fn = readdir($dh))) {
			next unless is_maildir_basename($fn);
			my $mime = maildir_file_load("$dir/$fn") or next;
			if ($filter) {
				my $ret = $filter->scrub($mime) or return;
				return if $ret == REJECT();
				$mime = $ret;
			}
			$im->add($mime);
		}
	}
	$im->done;
}

# asctime: From example@example.com Fri Jun 23 02:56:55 2000
my $from_strict = qr/^From \S+ +\S+ \S+ +\S+ [^:]+:[^:]+:[^:]+ [^:]+/;

sub mb_add ($$$$) {
	my ($im, $variant, $filter, $msg) = @_;
	$$msg =~ s/(\r?\n)+\z/$1/s;
	my $mime = PublicInbox::MIME->new($msg);
	if ($variant eq 'mboxrd') {
		$$msg =~ s/^>(>*From )/$1/sm;
	} elsif ($variant eq 'mboxo') {
		$$msg =~ s/^>From /From /sm;
	}
	if ($filter) {
		my $ret = $filter->scrub($mime) or return;
		return if $ret == REJECT();
		$mime = $ret;
	}
	$im->add($mime)
}

sub import_mbox {
	my ($self, $fh, $variant) = @_;
	if ($variant !~ /\A(?:mboxrd|mboxo)\z/) {
		die "variant must be 'mboxrd' or 'mboxo'\n";
	}
	my $im = $self->importer(1);
	my $prev = undef;
	my $msg = '';
	my $filter = $self->filter;
	while (defined(my $l = <$fh>)) {
		if ($l =~ /$from_strict/o) {
			if (!defined($prev) || $prev =~ /^\r?$/) {
				mb_add($im, $variant, $filter, \$msg) if $msg;
				$msg = '';
				$prev = $l;
				next;
			}
			warn "W[$.] $l\n";
		}
		$prev = $l;
		$msg .= $l;
	}
	mb_add($im, $variant, $filter, \$msg) if $msg;
	$im->done;
}

1;
