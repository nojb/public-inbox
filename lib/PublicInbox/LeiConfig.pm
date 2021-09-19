# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
package PublicInbox::LeiConfig;
use strict;
use v5.10.1;
use PublicInbox::PktOp;

sub cfg_do_edit ($;$) {
	my ($self, $reason) = @_;
	my $lei = $self->{lei};
	$lei->pgr_err($reason) if defined $reason;
	my $cmd = [ qw(git config --edit -f), $self->{-f} ];
	my $env = { GIT_CONFIG => $self->{-f} };
	$self->cfg_edit_begin if $self->can('cfg_edit_begin');
	# run in script/lei foreground
	my ($op_c, $op_p) = PublicInbox::PktOp->pair;
	# $op_p will EOF when $EDITOR is done
	$op_c->{ops} = { '' => [\&cfg_edit_done, $self] };
	$lei->send_exec_cmd([ @$lei{qw(0 1 2)}, $op_p->{op_p} ], $cmd, $env);
}

sub cfg_edit_done { # PktOp
	my ($self) = @_;
	eval {
		my $cfg = $self->{lei}->cfg_dump($self->{-f}, $self->{lei}->{2})
			// return cfg_do_edit($self, "\n");
		$self->cfg_verify($cfg) if $self->can('cfg_verify');
	};
	$self->{lei}->fail($@) if $@;
}

sub lei_config {
	my ($lei, @argv) = @_;
	$lei->{opt}->{'config-file'} and return $lei->fail(
		"config file switches not supported by `lei config'");
	return $lei->_config(@argv) unless $lei->{opt}->{edit};
	my $f = $lei->_lei_cfg(1)->{-f};
	my $self = bless { lei => $lei, -f => $f }, __PACKAGE__;
	cfg_do_edit($self);
}

1;
