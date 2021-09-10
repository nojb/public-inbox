use Plack::Builder;
use PublicInbox::WWW;
my $www = PublicInbox::WWW->new;
$www->preload;
builder {
	enable 'Head';
	mount '/pfx' => builder { sub { $www->call(@_) } };
	mount '/' => builder { sub { $www->call(@_) } };
};
