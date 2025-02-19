#!/usr/bin/perl

# (C) Sergey Kandaurov
# (C) Nginx, Inc.

# Tests for absolute_redirect directive and Location escaping.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP3;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

eval { require Crypt::Misc; die if $Crypt::Misc::VERSION < 0.067; };
plan(skip_all => 'CryptX version >= 0.067 required') if $@;

my $t = Test::Nginx->new()->has(qw/http http_v3 proxy rewrite/)
	->has_daemon('openssl')->plan(23);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    absolute_redirect off;

    ssl_certificate_key localhost.key;
    ssl_certificate localhost.crt;

    server {
        listen       127.0.0.1:%%PORT_8980_UDP%% quic;
        server_name  on;

        absolute_redirect on;
        error_page 400 /return301;

        location / { }

        location /auto/ {
            proxy_pass http://127.0.0.1:8080;
        }

        location "/auto sp/" {
            proxy_pass http://127.0.0.1:8080;
        }

        location /return301 {
            return 301 /redirect;
        }

        location /return301/name {
            return 301 /redirect;
            server_name_in_redirect on;
        }

        location /return301/port {
            return 301 /redirect;
            port_in_redirect off;
        }

        location /i/ {
            alias %%TESTDIR%%/;
        }
    }

    server {
        listen       127.0.0.1:%%PORT_8980_UDP%% quic;
        server_name  off;

        location / { }

        location /auto/ {
            proxy_pass http://127.0.0.1:8080;
        }

        location "/auto sp/" {
            proxy_pass http://127.0.0.1:8080;
        }

        location '/auto "#%<>?\^`{|}/' {
            proxy_pass http://127.0.0.1:8080;
        }

        location /return301 {
            return 301 /redirect;
        }

        location /i/ {
            alias %%TESTDIR%%/;
        }
    }
}

EOF

$t->write_file('openssl.conf', <<EOF);
[ req ]
default_bits = 2048
encrypt_key = no
distinguished_name = req_distinguished_name
[ req_distinguished_name ]
EOF

my $d = $t->testdir();

foreach my $name ('localhost') {
	system('openssl req -x509 -new '
		. "-config $d/openssl.conf -subj /CN=$name/ "
		. "-out $d/$name.crt -keyout $d/$name.key "
		. ">>$d/openssl.out 2>&1") == 0
		or die "Can't create certificate for $name: $!\n";
}

mkdir($t->testdir() . '/dir');
mkdir($t->testdir() . '/dir sp');

$t->run();

###############################################################################

my $p = port(8980);

like(get('on', '/dir'), qr!Location: https://on:$p/dir/\x0d?$!m, 'directory');
like(get('on', '/i/dir'), qr!Location: https://on:$p/i/dir/\x0d?$!m,
	'directory alias');

like(get('on', '/dir%20sp'), qr!Location: https://on:$p/dir%20sp/\x0d?$!m,
	'directory escaped');
like(get('on', '/dir%20sp?a=b'),
	qr!Location: https://on:$p/dir%20sp/\?a=b\x0d?$!m,
	'directory escaped args');

like(get('on', '/auto'), qr!Location: https://on:$p/auto/\x0d?$!m, 'auto');
like(get('on', '/auto?a=b'), qr!Location: https://on:$p/auto/\?a=b\x0d?$!m,
	'auto args');

like(get('on', '/auto%20sp'), qr!Location: https://on:$p/auto%20sp/\x0d?$!m,
	'auto escaped');
like(get('on', '/auto%20sp?a=b'),
	qr!Location: https://on:$p/auto%20sp/\?a=b\x0d?$!m,
	'auto escaped args');

like(get('on', '/return301'), qr!Location: https://on:$p/redirect\x0d?$!m,
	'return');

like(get('host', '/return301/name'), qr!Location: https://on:$p/redirect\x0d?!m,
	'server_name_in_redirect on');
like(get('host', '/return301'), qr!Location: https://host:$p/redirect\x0d?$!m,
	'server_name_in_redirect off - using host');
my $ph = IO::Socket::INET->new("127.0.0.1:$p")->peerhost();
like(get('.', '/return301'), qr!Location: https://$ph:$p/redirect\x0d?$!m,
	'invalid host - using local sockaddr');
like(get('host', '/return301/port'), qr!Location: https://host/redirect\x0d?$!m,
	'port_in_redirect off');

like(get('off', '/dir'), qr!Location: /dir/\x0d?$!m, 'off directory');
like(get('off', '/i/dir'), qr!Location: /i/dir/\x0d?$!m, 'off directory alias');

like(get('off', '/dir%20sp'), qr!Location: /dir%20sp/\x0d?$!m,
	'off directory escaped');
like(get('off', '/dir%20sp?a=b'), qr!Location: /dir%20sp/\?a=b\x0d?$!m,
	'off directory escaped args');

like(get('off', '/auto'), qr!Location: /auto/\x0d?$!m, 'off auto');
like(get('off', '/auto?a=b'), qr!Location: /auto/\?a=b\x0d?$!m,
	'off auto args');

like(get('off', '/auto%20sp'), qr!Location: /auto%20sp/\x0d?$!m,
	'auto escaped');
like(get('off', '/auto%20sp?a=b'), qr!Location: /auto%20sp/\?a=b\x0d?$!m,
	'auto escaped args');

like(get('off', '/return301'), qr!Location: /redirect\x0d?$!m, 'off return');

# per RFC 3986, these characters are not allowed unescaped:
# %00-%1F, %7F-%FF, " ", """, "<", ">", "\", "^", "`", "{", "|", "}"
# additionally, all characters in ESCAPE_URI: "?", "%", "#"

SKIP: {
skip 'win32', 1 if $^O eq 'MSWin32';

like(get('off', '/auto%20%22%23%25%3C%3E%3F%5C%5E%60%7B%7C%7D'),
	qr!Location: /auto%20%22%23%25%3C%3E%3F%5C%5E%60%7B%7C%7D/\x0d?$!m,
	'auto escaped strict');

}

###############################################################################

sub get {
	my ($host, $uri) = @_;

	my $s = Test::Nginx::HTTP3->new();
	my $sid = $s->new_stream({ host => $host, path => $uri });
	my $frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

	my ($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
	return 'Location: ' . $frame->{headers}->{'location'};
}

###############################################################################
