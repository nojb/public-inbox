# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# for the "lei init" command, not sure if it's even needed...
package PublicInbox::LeiInit;
use v5.10.1;

sub lei_init {
	my ($self, $dir) = @_;
	my $cfg = $self->_lei_cfg(1);
	my $cur = $cfg->{'leistore.dir'};
	$dir //= $self->store_path;
	$dir = $self->rel2abs($dir);
	my @cur = stat($cur) if defined($cur);
	$cur = $self->canonpath_harder($cur // $dir);
	my @dir = stat($dir);
	my $exists = "# leistore.dir=$cur already initialized" if @dir;
	if (@cur) {
		if ($cur eq $dir) {
			$self->_lei_store(1)->done;
			return $self->qerr($exists);
		}

		# some folks like symlinks and bind mounts :P
		if (@dir && "@cur[1,0]" eq "@dir[1,0]") {
			$self->_config('leistore.dir', $dir);
			$self->_lei_store(1)->done;
			return $self->qerr("$exists (as $cur)");
		}
		return $self->fail(<<"");
E: leistore.dir=$cur already initialized and it is not $dir

	}
	$self->_config('leistore.dir', $dir);
	$self->_lei_store(1)->done;
	$exists //= "# leistore.dir=$dir newly initialized";
	$self->qerr($exists);
}

1;
