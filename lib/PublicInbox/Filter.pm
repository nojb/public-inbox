# Copyright (C) 2013, Eric Wong <normalperson@yhbt.net> and all contributors
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

# start with the same defaults as mailman
our $BAD_EXT = qr/\.(?:exe|bat|cmd|com|pif|scr|vbs|cpl)\z/i;
our $MIME_HTML = qr!\btext/html\b!i;
our $MIME_TEXT_ANY = qr!\btext/[a-z0-9\+\._-]+\b!i;

# this is highly opinionated delivery
# returns 0 only if there is nothing to deliver
sub run {
	my ($class, $simple) = @_;

	my $content_type = $simple->header("Content-Type") || "text/plain";

	# kill potentially bad/confusing headers
	# Note: ssoma already does this, but since we mangle the message,
	# we should do this before it gets to ssoma.
	# We also kill Mail-{Followup,Reply}-To and Reply-To headers due to
	# the nature of public-inbox having no real subscribers.
	foreach my $d (qw(status lines content-length
			mail-followup-to mail-reply-to reply-to)) {
		$simple->header_set($d);
	}

	if ($content_type =~ m!\btext/plain\b!i) {
		return 1; # yay, nothing to do
	} elsif ($content_type =~ $MIME_HTML) {
		# HTML-only, non-multipart
		my $body = $simple->body;
		my $ct_parsed = parse_content_type($content_type);
		dump_html(\$body, $ct_parsed->{attributes}->{charset});
		replace_body($simple, $body);
		return 1;
	} elsif ($content_type =~ m!\bmultipart/!i) {
		return strip_multipart($simple, $content_type);
	} else {
		replace_body($simple, "$content_type message scrubbed");
		return 0;
	}
}

sub replace_part {
	my ($simple, $part, $type) = ($_[0], $_[1], $_[3]);
	# don't copy $_[2], that's the body (it may be huge)

	# Email::MIME insists on setting Date:, so just set it consistently
	# to avoid conflicts to avoid git merge conflicts in a split brain
	# situation.
	unless (defined $part->header('Date')) {
		my $date = $simple->header('Date') ||
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
	my ($simple, $part) = @_;
	my $body = $part->body;
	my $ct_parsed = parse_content_type($part->content_type);
	dump_html(\$body, $ct_parsed->{attributes}->{charset});
	replace_part($simple, $part, $body, 'text/plain');
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
# it to something safer, smaller and harder-to-track.
sub strip_multipart {
	my ($simple, $content_type) = @_;
	my $mime = Email::MIME->new($simple->as_string);

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
			$rejected++;
			return;
		}

		my $part_type = $part->content_type;
		if ($part_type =~ m!\btext/plain\b!i) {
			push @keep, $part;
		} elsif ($part_type =~ $MIME_HTML) {
			push @html, $part;
		} elsif ($part_type =~ $MIME_TEXT_ANY) {
			# Give other text attachments the benefit of the doubt,
			# here?  Could be source code or script the user wants
			# help with.

			push @keep, $part;
		} elsif ($part_type =~ m!\Aapplication/octet-stream\z!i) {
			# unfortunately, some mailers don't set correct types,
			# let messages of unknown type through but do not
			# change the sender-specified type
			if (recheck_type_ok($part)) {
				push @keep, $part;
			} else {
				$rejected++;
			}
		} elsif ($part_type =~ m!\Aapplication/pgp-signature\z!i) {
			# PGP signatures are not huge, we may keep them.
			# They can only be valid if it's the last element,
			# so we keep them iff the message is unmodified:
			if ($rejected == 0 && !@html) {
				push @keep, $part;
			}
		} else {
			# reject everything else, including non-PGP signatures
			$rejected++;
		}
	});

	if ($content_type =~ m!\bmultipart/alternative\b!i) {
		if (scalar @keep == 1) {
			return collapse($simple, $keep[0]);
		}
	} else { # convert HTML parts to plain text
		foreach my $part (@html) {
			html_part_to_text($simple, $part);
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
		$simple->body_set($mime->body_raw);
		mark_changed($simple);
	} # else: no changes

	return $ok;
}

sub mark_changed {
	my ($simple) = @_;
	$simple->header_set("X-Content-Filtered-By", __PACKAGE__ ." $VERSION");
}

sub collapse {
	my ($simple, $part) = @_;
	$simple->header_set("Content-Type", $part->content_type);
	$simple->body_set($part->body_raw);
	mark_changed($simple);
	return 1;
}

sub replace_body {
	my $simple = $_[0];
	$simple->body_set($_[1]);
	$simple->header_set("Content-Type", "text/plain");
	if ($simple->header("Content-Transfer-Encoding")) {
		$simple->header_set("Content-Transfer-Encoding", undef);
	}
	mark_changed($simple);
}

# Check for display-able text, no messed up binaries
# Note: we can not rewrite the message with the detected mime type
sub recheck_type_ok {
	my ($part) = @_;
	my $s = $part->body;
	((bytes::length($s) < 0x10000) &&
		($s =~ /\A([\P{XPosixPrint}\f\n\r\t]+)\z/))
}

1;
