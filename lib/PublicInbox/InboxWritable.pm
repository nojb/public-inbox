# Copyright (C) 2018-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Extends read-only Inbox for writing
package PublicInbox::InboxWritable;
use strict;
use v5.10.1;
use parent qw(PublicInbox::Inbox Exporter);
use PublicInbox::Import;
use PublicInbox::Filter::Base qw(REJECT);
use Errno qw(ENOENT);
our @EXPORT_OK = qw(eml_from_path warn_ignore_cb);

use constant {
	PERM_UMASK => 0,
	OLD_PERM_GROUP => 1,
	OLD_PERM_EVERYBODY => 2,
	PERM_GROUP => 0660,
	PERM_EVERYBODY => 0664,
};

sub new {
	my ($class, $ibx, $creat_opt) = @_;
	return $ibx if ref($ibx) eq $class;
	my $self = bless $ibx, $class;

	# TODO: maybe stop supporting this
	if ($creat_opt) { # for { nproc => $N }
		$self->{-creat_opt} = $creat_opt;
		init_inbox($self) if $self->version == 1;
	}
	$self;
}

sub assert_usable_dir {
	my ($self) = @_;
	my $dir = $self->{inboxdir};
	return $dir if defined($dir) && $dir ne '';
	die "no inboxdir defined for $self->{name}\n";
}

sub _init_v1 {
	my ($self, $skip_artnum) = @_;
	if (defined($self->{indexlevel}) || defined($skip_artnum)) {
		require PublicInbox::SearchIdx;
		require PublicInbox::Msgmap;
		my $sidx = PublicInbox::SearchIdx->new($self, 1); # just create
		$sidx->begin_txn_lazy;
		my $mm = PublicInbox::Msgmap->new($self->{inboxdir}, 1);
		if (defined $skip_artnum) {
			$mm->{dbh}->begin_work;
			$mm->skip_artnum($skip_artnum);
			$mm->{dbh}->commit;
		}
		undef $mm; # ->created_at set
		$sidx->commit_txn_lazy;
	} else {
		open my $fh, '>>', "$self->{inboxdir}/ssoma.lock" or
			die "$self->{inboxdir}/ssoma.lock: $!\n";
	}
}

sub init_inbox {
	my ($self, $shards, $skip_epoch, $skip_artnum) = @_;
	if ($self->version == 1) {
		my $dir = assert_usable_dir($self);
		PublicInbox::Import::init_bare($dir);
		$self->with_umask(\&_init_v1, $self, $skip_artnum);
	} else {
		my $v2w = importer($self);
		$v2w->init_inbox($shards, $skip_epoch, $skip_artnum);
	}
}

sub importer {
	my ($self, $parallel) = @_;
	my $v = $self->version;
	if ($v == 2) {
		eval { require PublicInbox::V2Writable };
		die "v2 not supported: $@\n" if $@;
		my $opt = $self->{-creat_opt};
		my $v2w = PublicInbox::V2Writable->new($self, $opt);
		$v2w->{parallel} = $parallel if defined $parallel;
		$v2w;
	} elsif ($v == 1) {
		my @arg = (undef, undef, undef, $self);
		PublicInbox::Import->new(@arg);
	} else {
		$! = 78; # EX_CONFIG 5.3.5 local configuration error
		die "unsupported inbox version: $v\n";
	}
}

sub filter {
	my ($self, $im) = @_;
	my $f = $self->{filter};
	if ($f && $f =~ /::/) {
		# v2 keeps msgmap open, which causes conflicts for filters
		# such as PublicInbox::Filter::RubyLang which overload msgmap
		# for a predictable serial number.
		if ($im && $self->version >= 2 && $self->{altid}) {
			$im->done;
		}

		my @args = (ibx => $self);
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

sub eml_from_path ($) {
	my ($path) = @_;
	if (open my $fh, '<', $path) {
		my $str = do { local $/; <$fh> } or return;
		PublicInbox::Eml->new(\$str);
	} else { # ENOENT is common with Maildir
		warn "failed to open $path: $!\n" if $! != ENOENT;
		undef;
	}
}

sub import_maildir {
	my ($self, $dir) = @_;
	my $im = $self->importer(1);

	foreach my $sub (qw(cur new tmp)) {
		-d "$dir/$sub" or die "$dir is not a Maildir (missing $sub)\n";
	}
	foreach my $sub (qw(cur new)) {
		opendir my $dh, "$dir/$sub" or die "opendir $dir/$sub: $!\n";
		while (defined(my $fn = readdir($dh))) {
			next unless is_maildir_basename($fn);
			my $mime = eml_from_path("$dir/$fn") or next;

			if (my $filter = $self->filter($im)) {
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
	if ($variant eq 'mboxrd') {
		$$msg =~ s/^>(>*From )/$1/gms;
	} elsif ($variant eq 'mboxo') {
		$$msg =~ s/^>From /From /gms;
	}
	my $mime = PublicInbox::Eml->new($msg);
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

sub _read_git_config_perm {
	my ($self) = @_;
	chomp(my $perm = $self->git->qx('config', 'core.sharedRepository'));
	$perm;
}

sub _git_config_perm {
	my $self = shift;
	my $perm = scalar @_ ? $_[0] : _read_git_config_perm($self);
	return PERM_UMASK if (!defined($perm) || $perm eq '');
	return PERM_UMASK if ($perm eq 'umask');
	return PERM_GROUP if ($perm eq 'group');
	if ($perm =~ /\A(?:all|world|everybody)\z/) {
		return PERM_EVERYBODY;
	}
	return PERM_GROUP if ($perm =~ /\A(?:true|yes|on|1)\z/);
	return PERM_UMASK if ($perm =~ /\A(?:false|no|off|0)\z/);

	my $i = oct($perm);
	return PERM_UMASK if ($i == PERM_UMASK);
	return PERM_GROUP if ($i == OLD_PERM_GROUP);
	return PERM_EVERYBODY if ($i == OLD_PERM_EVERYBODY);

	if (($i & 0600) != 0600) {
		die "core.sharedRepository mode invalid: ".
		    sprintf('%.3o', $i) . "\nOwner must have permissions\n";
	}
	($i & 0666);
}

sub _umask_for {
	my ($perm) = @_; # _git_config_perm return value
	my $rv = $perm;
	return umask if $rv == 0;

	# set +x bit if +r or +w were set
	$rv |= 0100 if ($rv & 0600);
	$rv |= 0010 if ($rv & 0060);
	$rv |= 0001 if ($rv & 0006);
	(~$rv & 0777);
}

sub with_umask {
	my ($self, $cb, @arg) = @_;
	my $old = umask($self->{umask} //= umask_prepare($self));
	my $rv = eval { $cb->(@arg) };
	my $err = $@;
	umask $old;
	die $err if $err;
	$rv;
}

sub umask_prepare {
	my ($self) = @_;
	my $perm = _git_config_perm($self);
	_umask_for($perm);
}

sub cleanup ($) {
	delete @{$_[0]}{qw(over mm git search)};
}

# warnings to ignore when handling spam mailboxes and maybe other places
sub warn_ignore {
	my $s = "@_";
	# Email::Address::XS warnings
	$s =~ /^Argument contains empty address at /
	|| $s =~ /^Element at index [0-9]+ contains /
	# PublicInbox::MsgTime
	|| $s =~ /^bogus TZ offset: .+?, ignoring and assuming \+0000/
	|| $s =~ /^bad Date: .+? in /
	# Encode::Unicode::UTF7
	|| $s =~ /^Bad UTF7 data escape at /
}

# this expects to be RHS in this assignment: "local $SIG{__WARN__} = ..."
sub warn_ignore_cb {
	my $cb = $SIG{__WARN__} // sub { print STDERR @_ };
	sub {
		return if warn_ignore(@_);
		$cb->(@_);
	}
}

# v2+ only, XXX: maybe we can just rely on ->max_git_epoch and remove
sub git_dir_latest {
	my ($self, $max) = @_;
	defined($$max = $self->max_git_epoch) ?
		"$self->{inboxdir}/git/$$max.git" : undef;
}

1;
