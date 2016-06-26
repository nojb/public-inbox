# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Represents a public-inbox (which may have multiple mailing addresses)
package PublicInbox::Inbox;
use strict;
use warnings;
use Scalar::Util qw(weaken isweak);
use PublicInbox::Git;
use PublicInbox::MID qw(mid2path);

sub new {
	my ($class, $opts) = @_;
	my $v = $opts->{address} ||= 'public-inbox@example.com';
	my $p = $opts->{-primary_address} = ref($v) eq 'ARRAY' ? $v->[0] : $v;
	$opts->{domain} = ($p =~ /\@(\S+)\z/) ? $1 : 'localhost';
	bless $opts, $class;
}

sub weaken_all {
	my ($self) = @_;
	foreach my $f (qw(git mm search)) {
		isweak($self->{$f}) or weaken($self->{$f});
	}
}

sub git {
	my ($self) = @_;
	$self->{git} ||= eval { PublicInbox::Git->new($self->{mainrepo}) };
}

sub mm {
	my ($self) = @_;
	$self->{mm} ||= eval { PublicInbox::Msgmap->new($self->{mainrepo}) };
}

sub search {
	my ($self) = @_;
	$self->{search} ||= eval { PublicInbox::Search->new($self->{mainrepo}) };
}

sub try_cat {
	my ($path) = @_;
	my $rv = '';
	if (open(my $fh, '<', $path)) {
		local $/;
		$rv = <$fh>;
	}
	$rv;
}

sub description {
	my ($self) = @_;
	my $desc = $self->{description};
	return $desc if defined $desc;
	$desc = try_cat("$self->{mainrepo}/description");
	chomp $desc;
	$desc =~ s/\s+/ /smg;
	$desc = '($GIT_DIR/description missing)' if $desc eq '';
	$self->{description} = $desc;
}

sub cloneurl {
	my ($self) = @_;
	my $url = $self->{cloneurl};
	return $url if $url;
	$url = try_cat("$self->{mainrepo}/cloneurl");
	my @url = split(/\s+/s, $url);
	chomp @url;
	$self->{cloneurl} = \@url;
}

sub base_url {
	my ($self, $prq) = @_; # Plack::Request
	if (defined $prq) {
		my $url = $prq->base->as_string;
		$url .= '/' if $url !~ m!/\z!; # for mount in Plack::Builder
		$url .= $self->{name} . '/';
	} else {
		# either called from a non-PSGI environment (e.g. NNTP/POP3)
		$self->{-base_url} ||= do {
			my $url = $self->{url} or return undef;
			# expand protocol-relative URLs to HTTPS if we're
			# not inside a web server
			$url = "https:$url" if $url =~ m!\A//!;
			$url .= '/' if $url !~ m!/\z!;
			$url;
		};
	}
}

sub nntp_usable {
	my ($self) = @_;
	my $ret = $self->mm && $self->search;
	$self->{mm} = $self->{search} = undef;
	$ret;
}

sub msg_by_path ($$;$) {
	my ($self, $path, $ref) = @_;
	# TODO: allow other refs:
	my $str = git($self)->cat_file('HEAD:'.$path, $ref);
	$$str =~ s/\A[\r\n]*From [^\r\n]*\r?\n//s;
	$str;
}

sub msg_by_mid ($$;$) {
	my ($self, $mid, $ref) = @_;
	msg_by_path($self, mid2path($mid), $ref);
}

1;
