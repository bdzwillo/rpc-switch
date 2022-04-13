#!/usr/bin/env perl

# tls listeners and client certificate authentication
#

use strict;
use warnings;

use Test::More;

use FindBin;
use lib "$FindBin::Bin/lib";
use TestSwitch;

BEGIN {
	plan skip_all => 'IO::Socket::SSL required'
		unless eval { require IO::Socket::SSL;
			require IO::Socket::SSL::Utils; 1 };
}

plan tests => 9;

my $sw = TestSwitch->new(tls => 1)->start;

# a client presenting the certificate gets in
#
{
	my $c = $sw->connect_tls(cert => 1);
	ok $c->greetings, 'a client with a certificate is greeted';
	is $c->greetings->{method}, 'rpcswitch.greetings',
		'the greeting comes from the switch';

	my $r = $c->hello('theEmployee', method => 'clientcert');
	ok $r->{result}[0], 'clientcert hello accepted';
	my $m = $c->call('rpcswitch.get_methods');
	is $m && $m->{result}[0], 'RES_OK',
		'clientcert hello authenticates the connection';
}

# the cnfile decides which accounts a common name may use
#
{
	my $c = $sw->connect_tls(cert => 1);
	my $r = $c->hello('nemo', method => 'clientcert');
	ok !$r->{result}[0], 'an account outside the cnfile is refused';
	like $sw->log, qr/user nemo not allowed for cn testclient/,
		'the refusal is logged with the common name';
}

# without a certificate the switch must not talk to us at all
#
{
	my $c = $sw->connect_tls;
	ok !$c->greetings, 'a client without a certificate gets no greeting';
	ok $c->eof, 'a client without a certificate gets no connection';
}

is $sw->stop, 0, 'switch shut down';
