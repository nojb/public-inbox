# Copyright (C) 2016-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Standalone PSGI app to handle HTTP(s) unsubscribe links generated
# by milters like examples/unsubscribe.milter to mailing lists.
#
# This does not depend on any other modules in the PublicInbox::*
# and ought to be usable with any mailing list software.
package PublicInbox::Unsubscribe;
use strict;
use warnings;
use Crypt::CBC;
use Plack::Util;
use MIME::Base64 qw(decode_base64url);
my @CODE_URL = qw(http://7fh6tueqddpjyxjmgtdiueylzoqt6pt7hec3pukyptlmohoowvhde4yd.onion/public-inbox.git
	https://public-inbox.org/public-inbox.git);
my @CT_HTML = ('Content-Type', 'text/html; charset=UTF-8');

sub new {
	my ($class, %opt) = @_;
	my $key_file = $opt{key_file};
	defined $key_file or die "`key_file' needed";
	open my $fh, '<', $key_file or die
		"failed to open key_file=$key_file: $!\n";
	my ($key, $iv);
	if (read($fh, $key, 8) != 8 || read($fh, $iv, 8) != 8 ||
				read($fh, my $end, 8) != 0) {
		die "key_file must be 16 bytes\n";
	}

	# these parameters were chosen to generate shorter parameters
	# to reduce the possibility of copy+paste errors
	my $cipher = Crypt::CBC->new(-key => $key,
			-iv => $iv,
			-header => 'none',
			-cipher => 'Blowfish');

	my $e = $opt{owner_email} or die "`owner_email' not specified\n";
	my $unsubscribe = $opt{unsubscribe} or
		die "`unsubscribe' callback not given\n";

	my $code_url = $opt{code_url} || \@CODE_URL;
	$code_url = [ $code_url ] if ref($code_url) ne 'ARRAY';
	bless {
		pi_cfg => $opt{pi_config}, # PublicInbox::Config
		owner_email => $opt{owner_email},
		cipher => $cipher,
		unsubscribe => $unsubscribe,
		contact => qq(<a\nhref="mailto:$e">$e</a>),
		code_url => $code_url,
		confirm => $opt{confirm},
	}, $class;
}

# entry point for PSGI
sub call {
	my ($self, $env) = @_;
	my $m = $env->{REQUEST_METHOD};
	if ($m eq 'GET' || $m eq 'HEAD') {
		$self->{confirm} ? confirm_prompt($self, $env)
				 : finalize_unsub($self, $env);
	} elsif ($m eq 'POST') {
		finalize_unsub($self, $env);
	} else {
		r($self, 405,
			Plack::Util::encode_html($m).' method not allowed');
	}
}

sub _user_list_addr {
	my ($self, $env) = @_;
	my ($blank, $u, $list) = split('/', $env->{PATH_INFO});

	if (!defined $u || $u eq '') {
		return r($self, 400, 'Bad request',
			'Missing encrypted email address in path component');
	}
	if (!defined $list && $list eq '') {
		return r($self, 400, 'Bad request',
			'Missing mailing list name in path component');
	}
	my $user = eval { $self->{cipher}->decrypt(decode_base64url($u)) };
	if (!defined $user || index($user, '@') < 1) {
		warn "error decrypting: $u: ", ($@ ? quotemeta($@) : ());
		$u = Plack::Util::encode_html($u);
		return r($self, 400, 'Bad request', "Failed to decrypt: $u");
	}

	# The URLs are too damn long if we have the encrypted domain
	# name in the PATH_INFO
	if (index($list, '@') < 0) {
		my $host = (split(':', $env->{HTTP_HOST}))[0];
		$list .= '@'.$host;
	}
	($user, $list);
}

sub confirm_prompt { # on GET
	my ($self, $env) = @_;
	my ($user_addr, $list_addr) = _user_list_addr($self, $env);
	return $user_addr if ref $user_addr;

	my $xl = Plack::Util::encode_html($list_addr);
	my $xu = Plack::Util::encode_html($user_addr);
	my @body = (
		"Confirmation required to remove", '',
		"\t$xu", '',
		"from the mailing list at", '',
		"\t$xl", '',
		'You will get one last email once you hit "Confirm" below:',
		qq(</pre><form\nmethod=post\naction="">) .
		qq(<input\ntype=submit\nvalue="Confirm" />) .
		'</form><pre>');

	push @body, archive_info($self, $env, $list_addr);

	r($self, 200, "Confirm unsubscribe for $xl", @body);
}

sub finalize_unsub { # on POST
	my ($self, $env) = @_;
	my ($user_addr, $list_addr) = _user_list_addr($self, $env);
	return $user_addr if ref $user_addr;

	my @archive = archive_info($self, $env, $list_addr);
	if (my $err = $self->{unsubscribe}->($user_addr, $list_addr)) {
		return r($self, 500, Plack::Util::encode_html($err), @archive);
	}

	my $xl = Plack::Util::encode_html($list_addr);
	r($self, 200, "Unsubscribed from $xl",
		'You may get one final goodbye message', @archive);
}

sub r {
	my ($self, $code, $title, @body) = @_;
	[ $code, [ @CT_HTML ], [
		"<html><head><title>$title</title></head><body><pre>".
		join("\n", "<b>$title</b>\n", @body) . '</pre><hr>'.
		"<pre>This page is available under AGPL-3.0+\n" .
		join('', map { "git clone $_\n" } @{$self->{code_url}}) .
		qq(Email $self->{contact} if you have any questions).
		'</pre></body></html>'
	] ];
}

sub archive_info {
	my ($self, $env, $list_addr) = @_;
	my $archive_url = $self->{archive_urls}->{$list_addr};

	unless ($archive_url) {
		if (my $cfg = $self->{pi_cfg}) {
			# PublicInbox::Config::lookup
			my $ibx = $cfg->lookup($list_addr);
			# PublicInbox::Inbox::base_url
			$archive_url = $ibx->base_url if $ibx;
		}
	}

	# protocol-relative URL:  "//example.com/" => "https://example.com/"
	if ($archive_url && $archive_url =~ m!\A//!) {
		$archive_url = "$env->{'psgi.url_scheme'}:$archive_url";
	}

	# maybe there are other places where we could map
	# list_addr => archive_url without ~/.public-inbox/config
	if ($archive_url) {
		$archive_url = Plack::Util::encode_html($archive_url);
		('',
		'HTML and git clone-able archives are available at:',
		qq(<a\nhref="$archive_url">$archive_url</a>))
	} else {
		('',
		'There ought to be archives for this list,',
		'but unfortunately the admin did not configure '.
		__PACKAGE__. ' to show you the URL');
	}
}

1;
