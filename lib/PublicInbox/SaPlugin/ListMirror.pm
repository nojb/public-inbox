# Copyright (C) 2016-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# SpamAssassin rules useful for running a mailing list mirror.  We want to:
# * ensure Received: headers are really from the list mail server
#   users expect.  This is to prevent malicious users from
#   injecting spam into mirrors without going through the expected
#   server
# * flag messages where the mailing list is Bcc:-ed since it is
#   common for spam to have wrong or non-existent To:/Cc: headers.

package PublicInbox::SaPlugin::ListMirror;
use strict;
use warnings;
use base qw(Mail::SpamAssassin::Plugin);

# constructor: register the eval rules
sub new {
	my ($class, $mail) = @_;

	# some boilerplate...
	$class = ref($class) || $class;
	my $self = $class->SUPER::new($mail);
	bless $self, $class;
	$mail->{conf}->{list_mirror_check} = [];
	$self->register_eval_rule('check_list_mirror_received');
	$self->register_eval_rule('check_list_mirror_bcc');
	$self->set_config($mail->{conf});
	$self;
}

sub check_list_mirror_received {
	my ($self, $pms) = @_;
	my $recvd = $pms->get('Received') || '';
	$recvd =~ s/\n.*\z//s;

	foreach my $cfg (@{$pms->{conf}->{list_mirror_check}}) {
		my ($hdr, $hval, $host_re, $addr_re) = @$cfg;
		my $v = $pms->get($hdr) or next;
		local $/ = "\n";
		chomp $v;
		next if $v ne $hval;
		return 1 if $recvd !~ $host_re;
	}

	0;
}

sub check_list_mirror_bcc {
	my ($self, $pms) = @_;
	my $tocc = $pms->get('ToCc');

	foreach my $cfg (@{$pms->{conf}->{list_mirror_check}}) {
		my ($hdr, $hval, $host_re, $addr_re) = @$cfg;
		defined $addr_re or next;
		my $v = $pms->get($hdr) or next;
		local $/ = "\n";
		chomp $v;
		next if $v ne $hval;
		return 1 if !$tocc || $tocc !~ $addr_re;
	}

	0;
}

# list_mirror HEADER HEADER_VALUE HOSTNAME_GLOB [LIST_ADDRESS]
# list_mirror X-Mailing-List git@vger.kernel.org *.kernel.org
# list_mirror List-Id <foo.example.org> *.example.org foo@example.org
sub config_list_mirror {
	my ($self, $key, $value, $line) = @_;

	defined $value or
		return $Mail::SpamAssassin::Conf::MISSING_REQUIRED_VALUE;

	my ($hdr, $hval, $host_glob, @extra) = split(/\s+/, $value);
	my $addr = shift @extra;

	if (defined $addr) {
		$addr !~ /\@/ and
			return $Mail::SpamAssassin::Conf::INVALID_VALUE;
		$addr = join('|', map { quotemeta } split(/,/, $addr));
		$addr = qr/\b$addr\b/i;
	}

	@extra and return $Mail::SpamAssassin::Conf::INVALID_VALUE;

	defined $host_glob or
		return $Mail::SpamAssassin::Conf::MISSING_REQUIRED_VALUE;

	my %patmap = ('*' => '\S+', '?' => '.', '[' => '[', ']' => ']');
	$host_glob =~ s!(.)!$patmap{$1} || "\Q$1"!ge;
	my $host_re = qr/\A\s*from\s+$host_glob(?:\s|$)/si;

	push @{$self->{list_mirror_check}}, [ $hdr, $hval, $host_re, $addr ];
}

sub set_config {
	my ($self, $conf) = @_;
	my @cmds;
	push @cmds, {
		setting => 'list_mirror',
		default => '',
		type => $Mail::SpamAssassin::Conf::CONF_TYPE_STRING,
		code => *config_list_mirror,
	};
	$conf->{parser}->register_commands(\@cmds);
}

1;
