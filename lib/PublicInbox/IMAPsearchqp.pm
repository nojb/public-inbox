# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# IMAP search query parser.  cf RFC 3501

# We currently compile Xapian queries to a string which is fed
# to Xapian's query parser.  However, we may use Xapian-provided
# Query object API to build an optree, instead.
package PublicInbox::IMAPsearchqp;
use strict;
use Parse::RecDescent;
use Time::Local qw(timegm);
use POSIX qw(strftime);
our $q = bless {}, __PACKAGE__; # singleton, reachable in generated P::RD
my @MoY = qw(JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC);
my %MM = map {; $MoY[$_-1] => sprintf('%02u', $_) } (1..12);

# IMAP to Xapian header search key mapping
my %IH2X = (
	TEXT => '',
	SUBJECT => 's:',
	BODY => 'b:',
	FROM => 'f:',
	TO => 't:',
	CC => 'c:',
	# BCC => 'bcc:', # TODO

	# IMAP allows searching arbitrary headers via
	# "HEADER $field_name $string" which gets silly expensive.
	# We only allow the headers we already index.
	'MESSAGE-ID' => 'm:',
	'LIST-ID' => 'l:',
	# KEYWORD # TODO ? dfpre,dfpost,...
);

sub uid_set_xap ($$) {
	my ($self, $seq_set) = @_;
	my @u;
	do {
		my $u = $self->{imap}->range_step(\$seq_set);
		die $u unless ref($u); # break out of the parser on error
		push @u, "uid:$u->[0]..$u->[1]";
	} while ($seq_set);
	push(@{$q->{xap}}, @u > 1 ? '('.join(' OR ', @u).')' : $u[0]);
}

sub xap_only ($;$) {
	my ($self, $query) = @_;
	delete $self->{sql}; # query too complex for over.sqlite3
	push @{$self->{xap}}, $query if defined($query);

	# looks like we can't use SQLite-only, convert SQLite UID
	# ranges to Xapian:
	if (my $uid = delete $self->{uid}) {
		uid_set_xap($self, $_) for @$uid;
	}
	1;
}

sub ih2x {
	my ($self, $field_name, $s) = @_; # $self == $q
	$s =~ /\A"(.*?)"\z/s and $s = $1;

	# AFAIK Xapian can't handle [*"] in probabilistic terms,
	# and it relies on lowercase
	my $xk = defined($field_name) ? ($IH2X{$field_name} // '') : '';
	xap_only($self,
		lc(join(' ', map { qq[$xk"$_"] } split(/[\*"\s]+/, $s))));
	1;
}

sub subq_enter {
	xap_only($q);
	my $old = delete($q->{xap}) // [];
	my $nr = push @{$q->{stack}}, $old;
	die 'BAD deep recursion' if $nr > 10;
	$q->{xap} = [];
}

sub subq_leave {
	my $child = delete $q->{xap};
	my $parent = $q->{xap} = pop @{$q->{stack}};
	push(@$parent, @$child > 1 ? '('.join(' ', @$child).')' : $child->[0]);
	1;
}

sub yyyymmdd ($) {
	my ($item) = @_;
	my ($dd, $mon, $yyyy) = split(/-/, $item->{date}, 3);
	my $mm = $MM{$mon} // die "BAD month: $mon";
	wantarray ? ($yyyy, $mm, sprintf('%02u', $dd))
		: timegm(0, 0, 0, $dd, $mm - 1, $yyyy);
}

sub SENTSINCE {
	my ($self, $item) = @_;
	my ($yyyy, $mm, $dd) = yyyymmdd($item);
	push @{$self->{xap}}, "d:$yyyy$mm$dd..";
	my $sql = $self->{sql} or return 1;
	my $ds = timegm(0, 0, 0, $dd, $mm - 1, $yyyy);
	$$sql .= " AND ds >= $ds";
}

sub SENTON {
	my ($self, $item) = @_;
	my ($yyyy, $mm, $dd) = yyyymmdd($item);
	my $ds = timegm(0, 0, 0, $dd, $mm - 1, $yyyy);
	my $end = $ds + 86399; # no leap day
	my $dt_end = strftime('%Y%m%d%H%M%S', gmtime($end));
	push @{$self->{xap}}, "dt:$yyyy$mm$dd"."000000..$dt_end";
	my $sql = $self->{sql} or return 1;
	$$sql .= " AND ds >= $ds AND ds <= $end";
}

sub SENTBEFORE {
	my ($self, $item) = @_;
	my ($yyyy, $mm, $dd) = yyyymmdd($item);
	push @{$self->{xap}}, "d:..$yyyy$mm$dd";
	my $sql = $self->{sql} or return 1;
	my $ds = timegm(0, 0, 0, $dd, $mm - 1, $yyyy);
	$$sql .= " AND ds <= $ds";
}

sub ON {
	my ($self, $item) = @_;
	my $ts = yyyymmdd($item);
	my $end = $ts + 86399; # no leap day
	push @{$self->{xap}}, "ts:$ts..$end";
	my $sql = $self->{sql} or return 1;
	$$sql .= " AND ts >= $ts AND ts <= $end";
}

sub BEFORE {
	my ($self, $item) = @_;
	my $ts = yyyymmdd($item);
	push @{$self->{xap}}, "ts:..$ts";
	my $sql = $self->{sql} or return 1;
	$$sql .= " AND ts <= $ts";
}

sub SINCE {
	my ($self, $item) = @_;
	my $ts = yyyymmdd($item);
	push @{$self->{xap}}, "ts:$ts..";
	my $sql = $self->{sql} or return 1;
	$$sql .= " AND ts >= $ts";
}

sub uid_set ($$) {
	my ($self, $seq_set) = @_;
	if ($self->{sql}) {
		push @{$q->{uid}}, $seq_set;
	} else { # we've gone Xapian-only
		uid_set_xap($self, $seq_set);
	}
	1;
}

sub msn_set {
	my ($self, $seq_set) = @_;
	PublicInbox::IMAP::msn_to_uid_range(
		$self->{msn2uid} //= $self->{imap}->msn2uid, $seq_set);
	uid_set($self, $seq_set);
}

my $prd = Parse::RecDescent->new(<<'EOG');
<nocheck>
{ my $q = $PublicInbox::IMAPsearchqp::q; }
search_key : CHARSET(?) search_key1(s) { $return = $q }
search_key1 : "ALL" | "RECENT" | "UNSEEN" | "NEW"
	| OR_search_keys
	| NOT_search_key
	| LARGER_number
	| SMALLER_number
	| SENTSINCE_date
	| SENTON_date
	| SENTBEFORE_date
	| SINCE_date
	| ON_date
	| BEFORE_date
	| FROM_string
	| HEADER_field_name_string
	| TO_string
	| CC_string
	| BCC_string
	| SUBJECT_string
	| UID_set
	| MSN_set
	| sub_query
	| <error>

charset : /\S+/
CHARSET : 'CHARSET' charset
{ $item{charset} =~ /\A(?:UTF-8|US-ASCII)\z/ ? 1 : die('NO [BADCHARSET]'); }

SENTSINCE_date : 'SENTSINCE' date { $q->SENTSINCE(\%item) }
SENTON_date : 'SENTON' date { $q->SENTON(\%item) }
SENTBEFORE_date : 'SENTBEFORE' date { $q->SENTBEFORE(\%item) }

SINCE_date : 'SINCE' date { $q->SINCE(\%item) }
ON_date : 'ON' date { $q->ON(\%item) }
BEFORE_date : 'BEFORE' date { $q->BEFORE(\%item) }

MSN_set : sequence_set { $q->msn_set($item{sequence_set}) }
UID_set : "UID" sequence_set { $q->uid_set($item{sequence_set}) }
LARGER_number : "LARGER" number { $q->xap_only("bytes:$item{number}..") }
SMALLER_number : "SMALLER" number { $q->xap_only("bytes:..$item{number}") }
# pass "NOT" through XXX is this right?
OP_NOT : "NOT" { $q->xap_only('NOT') }
NOT_search_key : OP_NOT search_key1
OP_OR : "OR" {
	$q->xap_only('OP_OR');
	my $cur = delete $q->{xap};
	push @{$q->{stack}}, $cur;
	$q->{xap} = [];
}
search_key_a : search_key1
{
	my $ka = delete $q->{xap};
	$q->{xap} = [];
	push @{$q->{stack}}, $ka;
}
OR_search_keys : OP_OR search_key_a search_key1
{
	my $kb = delete $q->{xap};
	my $ka = pop @{$q->{stack}};
	my $xap = $q->{xap} = pop @{$q->{stack}};
	my $op = pop @$xap;
	$op eq 'OP_OR' or die "BAD expected OR: $op";
	$ka = @$ka > 1 ? '('.join(' ', @$ka).')' : $ka->[0];
	$kb = @$kb > 1 ? '('.join(' ', @$kb).')' : $kb->[0];
	push @$xap, "($ka OR $kb)";
}
HEADER_field_name_string : "HEADER" field_name string
{
	$q->ih2x($item{field_name}, $item{string});
}
FROM_string : "FROM" string { $q->ih2x('FROM', $item{string}) }
TO_string : "TO" string { $q->ih2x('TO', $item{string}) }
CC_string : "CC" string { $q->ih2x('CC', $item{string}) }
BCC_string : "BCC" string { $q->ih2x('BCC', $item{string}) }
SUBJECT_string : "SUBJECT" string { $q->ih2x('SUBJECT', $item{string}) }
op_subq_enter : '(' { $q->subq_enter }
sub_query : op_subq_enter search_key1(s) ')' { $q->subq_leave }

field_name : /[\x21-\x39\x3b-\x7e]+/
string : quoted | literal
literal : /[^"\(\) \t]+/ # bogus, I know
quoted : /"[^"]*"/
number : /[0-9]+/
date : /[0123]?[0-9]-[A-Z]{3}-[0-9]{4,}/
sequence_set : /\A[0-9][0-9,:]*[0-9\*]?\z/
EOG

sub parse {
	my ($imap, $query) = @_;
	my $sql = '';
	%$q = (sql => \$sql, imap => $imap); # imap = PublicInbox::IMAP obj
	# $::RD_TRACE = 1;
	my $res = eval { $prd->search_key(uc($query)) };
	return $@ if $@ && $@ =~ /\A(?:BAD|NO) /;
	return 'BAD unexpected result' if !$res || $res != $q;
	if (exists $q->{sql}) {
		delete $q->{xap};
		if (my $uid = delete $q->{uid}) {
			my @u;
			for my $uid_set (@$uid) {
				my $u = $q->{imap}->range_step(\$uid_set);
				return $u if !ref($u);
				push @u, "num >= $u->[0] AND num <= $u->[1]";
			}
			$sql .= ' AND ('.join(' OR ', @u).')';
		}
	} else {
		$q->{xap} = join(' ', @{$q->{xap}});
	}
	delete @$q{qw(imap msn2uid)};
	$q;
}

1
