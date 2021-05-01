#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10; use PublicInbox::TestCommon;
use PublicInbox::MboxReader;
my $test_tor = $ENV{TEST_TOR};
plan skip_all => "TEST_TOR unset" unless $test_tor;
unless ($test_tor =~ m!\Asocks5h://!i) {
	my $default = 'socks5h://127.0.0.1:9050';
	diag "using $default (set TEST_TOR=socks5h://ADDR:PORT to override)";
	$test_tor = $default;
}
my $onion = $ENV{TEST_ONION_HOST} //'ou63pmih66umazou.onion';
my $ng = 'inbox.comp.mail.public-inbox.meta';
my $nntp_url = $ENV{TEST_NNTP_ONION_URL} // "nntp://$onion/$ng";
my $imap_url = $ENV{TEST_IMAP_ONION_URL} // "imap://$onion/$ng.0";
my @cnv = qw(lei convert -o mboxrd:/dev/stdout);
my @proxy_cli = ("--proxy=$test_tor");
my $proxy_cfg = "proxy=$test_tor";
test_lei(sub {
	my $run = {};
	for my $args ([$nntp_url, @proxy_cli], [$imap_url, @proxy_cli],
			[ $nntp_url, '-c', "nntp.$proxy_cfg" ],
			[ $imap_url, '-c', "imap.$proxy_cfg" ]) {
		pipe(my ($r, $w)) or xbail "pipe: $!";
		my $cmd = [@cnv, @$args];
		my $td = start_script($cmd, undef, { 1 => $w, run_mode => 0 });
		$args->[0] =~ s!\A(.+?://).*!$1...!;
		my $key = "@$args";
		ok($td, "$key running");
		$run->{$key} = { td => $td, r => $r };
	}
	while (my ($key, $x) = each %$run) {
		my ($td, $r) = delete(@$x{qw(td r)});
		eval {
			PublicInbox::MboxReader->mboxrd($r, sub {
				my ($eml) = @_;
				if ($key =~ m!\Anntps?://!i) {
					for (qw(Xref Newsgroups Path)) {
						$eml->header_set($_);
					}
				}
				push @{$x->{eml}}, $eml;
				close $r;
				$td->kill('-INT');
				die "$key done\n";
			});
		};
		chomp(my $done = $@);
		like($done, qr/\Q$key\E done/, $done);
		$td->join;
	}
	my @keys = keys %$run;
	my $first_key = shift @keys;
	for my $key (@keys) {
		is_deeply($run->{$key}, $run->{$first_key},
			"`$key' matches `$first_key'");
	}
});

done_testing;
