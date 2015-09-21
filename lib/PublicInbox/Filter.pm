# Copyright (C) 2013-2015 all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
#
# This only exposes one function: run
# Note: the settings here are highly opinionated.  Obviously, this is
# Free Software (AGPLv3), so you may change it if you host yourself.
package PublicInbox::Filter;
use strict;
use warnings;
use Email::MIME;
use Email::MIME::ContentType qw/parse_content_type/;
use Email::Filter;
use IPC::Run;
our $VERSION = '0.0.1';
use constant NO_HTML => '*** We only accept plain-text email, no HTML ***';

# start with the same defaults as mailman
our $BAD_EXT = qr/\.(exe|bat|cmd|com|pif|scr|vbs|cpl|zip)\s*\z/i;
our $MIME_HTML = qr!\btext/x?html\b!i;
our $MIME_TEXT_ANY = qr!\btext/[a-z0-9\+\._-]+\b!i;

# this is highly opinionated delivery
# returns 0 only if there is nothing to deliver
sub run {
	my ($class, $mime, $filter) = @_;

	my $content_type = $mime->header('Content-Type') || 'text/plain';

	# kill potentially bad/confusing headers
	# Note: ssoma already does this, but since we mangle the message,
	# we should do this before it gets to ssoma.
	# We also kill Mail-{Followup,Reply}-To and Reply-To headers due to
	# the nature of public-inbox having no real subscribers.
	foreach my $d (qw(status lines content-length
			mail-followup-to mail-reply-to reply-to)) {
		$mime->header_set($d);
	}

	if ($content_type =~ m!\btext/plain\b!i) {
		return 1; # yay, nothing to do
	} elsif ($content_type =~ $MIME_HTML) {
		$filter->reject(NO_HTML) if $filter;
		# HTML-only, non-multipart
		my $body = $mime->body;
		my $ct_parsed = parse_content_type($content_type);
		dump_html(\$body, $ct_parsed->{attributes}->{charset});
		replace_body($mime, $body);
		return 1;
	} elsif ($content_type =~ m!\bmultipart/!i) {
		return strip_multipart($mime, $content_type, $filter);
	} else {
		replace_body($mime, "$content_type message scrubbed");
		return 0;
	}
}

sub replace_part {
	my ($mime, $part, $type) = ($_[0], $_[1], $_[3]);
	# don't copy $_[2], that's the body (it may be huge)

	# Email::MIME insists on setting Date:, so just set it consistently
	# to avoid conflicts to avoid git merge conflicts in a split brain
	# situation.
	unless (defined $part->header('Date')) {
		my $date = $mime->header('Date') ||
		           'Thu, 01 Jan 1970 00:00:00 +0000';
		$part->header_set('Date', $date);
	}

	$part->charset_set(undef);
	$part->name_set(undef);
	$part->filename_set(undef);
	$part->format_set(undef);
	$part->encoding_set('8bit');
	$part->disposition_set(undef);
	$part->content_type_set($type);
	$part->body_set($_[2]);
}

# converts one part of a multipart message to text
sub html_part_to_text {
	my ($mime, $part) = @_;
	my $body = $part->body;
	my $ct_parsed = parse_content_type($part->content_type);
	dump_html(\$body, $ct_parsed->{attributes}->{charset});
	replace_part($mime, $part, $body, 'text/plain');
}

# modifies $_[0] in place
sub dump_html {
	my ($body, $charset) = @_;
	$charset ||= 'US-ASCII';
	my @cmd = qw(lynx -stdin -stderr -dump);
	my $out = "";
	my $err = "";

	# be careful about remote command injection!
	if ($charset =~ /\A([A-Za-z0-9\-]+)\z/) {
		push @cmd, "-assume_charset=$charset";
	}
	if (IPC::Run::run(\@cmd, $body, \$out, \$err)) {
		$out =~ s/\r\n/\n/sg;
		$$body = $out;
	} else {
		# give them an ugly version:
		$$body = "public-inbox HTML conversion failed: $err\n" .
			 $$body . "\n";
	}
}

# this is to correct user errors and not expected to cover all corner cases
# if users don't want to hit this, they should be sending text/plain messages
# unfortunately, too many people send HTML mail and we'll attempt to convert
# it to something safer, smaller and harder-to-spy-on-users-with.
sub strip_multipart {
	my ($mime, $content_type, $filter) = @_;

	my (@html, @keep);
	my $rejected = 0;
	my $ok = 1;

	# scan through all parts once
	$mime->walk_parts(sub {
		my ($part) = @_;
		return if $part->subparts; # walk_parts already recurses

		# some extensions are just bad, reject them outright
		my $fn = $part->filename;
		if (defined($fn) && $fn =~ $BAD_EXT) {
			$filter->reject("Bad file type: $1") if $filter;
			$rejected++;
			return;
		}

		my $part_type = $part->content_type || '';
		if ($part_type =~ m!\btext/plain\b!i) {
			push @keep, $part;
		} elsif ($part_type =~ $MIME_HTML) {
			$filter->reject(NO_HTML) if $filter;
			push @html, $part;
		} elsif ($part_type =~ $MIME_TEXT_ANY) {
			# Give other text attachments the benefit of the doubt,
			# here?  Could be source code or script the user wants
			# help with.

			push @keep, $part;
		} elsif ($part_type eq '' ||
		         $part_type =~ m!\bapplication/octet-stream\b!i) {
			# unfortunately, some mailers don't set correct types,
			# let messages of unknown type through but do not
			# change the sender-specified type
			if (recheck_type_ok($part)) {
				push @keep, $part;
			} elsif ($filter) {
				$filter->reject('no attachments')
			} else {
				$rejected++;
			}
		} elsif ($part_type =~ m!\bapplication/pgp-signature\b!i) {
			# PGP signatures are not huge, we may keep them.
			# They can only be valid if it's the last element,
			# so we keep them iff the message is unmodified:
			if ($rejected == 0 && !@html) {
				push @keep, $part;
			}
		} else {
			$filter->reject('no attachments') if $filter;
			# reject everything else, including non-PGP signatures
			$rejected++;
		}
	});

	if ($content_type =~ m!\bmultipart/alternative\b!i) {
		if (scalar @keep == 1) {
			return collapse($mime, $keep[0]);
		}
	} else { # convert HTML parts to plain text
		foreach my $part (@html) {
			html_part_to_text($mime, $part);
			push @keep, $part;
		}
	}

	if (@keep == 0) {
		@keep = (Email::MIME->create(
			attributes => {
				content_type => 'text/plain',
				charset => 'US-ASCII',
				encoding => '8bit',
			},
			body_str => 'all attachments scrubbed by '. __PACKAGE__
		));
		$ok = 0;
	}
	if (scalar(@html) || $rejected) {
		$mime->parts_set(\@keep);
		$mime->body_set($mime->body_raw);
		mark_changed($mime);
	} # else: no changes

	return $ok;
}

sub mark_changed {
	my ($mime) = @_;
	$mime->header_set('X-Content-Filtered-By', __PACKAGE__ ." $VERSION");
}

sub collapse {
	my ($mime, $part) = @_;
	$mime->header_set('Content-Type', $part->content_type);
	$mime->body_set($part->body_raw);
	my $cte = $part->header('Content-Transfer-Encoding');
	if (defined($cte) && $cte ne '') {
		$mime->header_set('Content-Transfer-Encoding', $cte);
	}
	mark_changed($mime);
	return 1;
}

sub replace_body {
	my $mime = $_[0];
	$mime->body_set($_[1]);
	$mime->header_set('Content-Type', 'text/plain');
	if ($mime->header('Content-Transfer-Encoding')) {
		$mime->header_set('Content-Transfer-Encoding', undef);
	}
	mark_changed($mime);
}

# Check for display-able text, no messed up binaries
# Note: we can not rewrite the message with the detected mime type
sub recheck_type_ok {
	my ($part) = @_;
	my $s = $part->body;
	((length($s) < 0x10000) &&
		($s =~ /\A([\P{XPosixPrint}\f\n\r\t]+)\z/))
}

1;
