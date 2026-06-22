#!/usr/bin/env perl

# greetings, rpcswitch.hello and the authenticated connection state

use strict;
use warnings;

use Test::More;

use FindBin;
use lib "$FindBin::Bin/lib";
use TestSwitch;

plan tests => 22;

my $sw = TestSwitch->new->start;

# the switch greets every connection
{
	my $c = $sw->connect;
	my $g = $c->greetings;
	is $g->{method}, 'rpcswitch.greetings', 'greeted on connect';
	is $g->{params}->{who}, 'rpcswitch', 'greeting comes from the switch';
	is $g->{params}->{version}, '1.0', 'greeting announces version 1.0';
	ok !exists $g->{id}, 'greeting is a notification';
}

# rpcswitch.ping needs no authentication, the rest does
{
	my $c = $sw->connect;
	my $r = $c->call('rpcswitch.ping');
	is $r->{result}, 'pong?', 'ping before hello';

	$r = $c->call('rpcswitch.get_methods');
	is $r->{error}->{code}, -32002, 'get_methods before hello refused';

	$r = $c->call('foo.add', {a => 1});
	is $r->{error}->{code}, -32002, 'configured method before hello refused';
	like $r->{error}->{message}, qr/requires an authenticated connection/,
		'configured method refused on an unauthenticated connection';
}

# a correct password is welcomed
{
	my $c = $sw->connect;
	my $r = $c->hello('theEmployee');
	ok $r->{result}[0], 'hello with the right password';
	like $r->{result}[1], qr/welcome to the rpcswitch theEmployee/,
		'hello with the right password gets a welcome';
	is $c->call('rpcswitch.get_methods')->{result}[0], 'RES_OK',
		'connection is authenticated after hello';
}

# every other hello is rejected and the connection closed
{
	for my $case (
		['wrong password', 'theEmployee', token => 'bogus'],
		['unknown user', 'nemo'],
		['unknown auth method', 'theEmployee', method => 'clientcert'],
	) {
		my ($name, $who, @args) = @$case;
		my $c = $sw->connect;
		my $r = $c->hello($who, @args);
		ok !$r->{result}[0], "hello rejected: $name";
		ok $c->closed(2),
			"connection closed after rejected hello: $name";
	}
}

# hello insists on all three parameters
{
	my $c = $sw->connect;
	my $r = $c->call('rpcswitch.hello', {method => 'password', token => 'x'});
	is $r->{error}->{code}, -32001, 'hello without who fails';
	like $r->{error}->{message}, qr/no who/,
		'hello without who says which parameter is missing';
}

# a second hello on an authenticated connection re-authenticates
{
	my $c = $sw->connect;
	$c->hello('theEmployee');
	my $r = $c->hello('deKlant');
	ok $r->{result}[0], 'second hello accepted';
	my $clients = $c->call('rpcswitch.get_clients')->{result}[1];
	my ($me) = grep { ($_->{who} // '') eq 'deKlant' } values %$clients;
	ok $me, 'second hello changes the identity of the connection';
}

is $sw->stop, 0, 'switch shut down';
