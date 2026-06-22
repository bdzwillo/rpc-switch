#!/usr/bin/env perl

# framing and json-rpc 2.0 conformance of the switch

use strict;
use warnings;

use Test::More;

use FindBin;
use lib "$FindBin::Bin/lib";
use TestSwitch;

plan tests => 29;

my $sw = TestSwitch->new->start;

# a malformed request is answered once and ends the connection
sub fatal {
	my ($name, $code, $re, $send) = @_;
	my $c = $sw->connect;
	$send->($c);
	my $r = $c->recv;
	is $r->{error}->{code}, $code, "$name: error $code";
	like $r->{error}->{message}, $re, "$name: message";
	ok $c->closed(2), "$name: connection closed";
}

fatal('undecodable json', -32700, qr/json decode failed/,
	sub { $_[0]->send_raw('5:bogus,') });

fatal('a json array', -32600, qr/not a json object/,
	sub { $_[0]->send([1, 2]) });

fatal('no jsonrpc member', -32600, qr/expected jsonrpc version 2\.0/,
	sub { $_[0]->send({id => 1, method => 'rpcswitch.ping', params => {}}) });

fatal('the wrong jsonrpc version', -32600, qr/expected jsonrpc version 2\.0/,
	sub { $_[0]->send({jsonrpc => '1.0', id => 1, method => 'rpcswitch.ping'}) });

fatal('a netstring over the maximum size', -32010, qr/netstring too big/,
	sub { $_[0]->send_raw('1000000:') });

# an invalid request without a framing error keeps the connection open
{
	my $c = $sw->connect;

	my $r = $c->call('rpcswitch.ping', [1]);
	is $r->{error}->{code}, -32602, 'positional parameters refused';
	like $r->{error}->{message}, qr/expects named params/,
		'positional parameters error asks for named params';

	$r = $c->call('rpcswitch.bogus');
	is $r->{error}->{code}, -32601, 'an unknown rpcswitch method is refused';

	$r = $c->call('no.such.method');
	is $r->{error}->{code}, -32601, 'an unconfigured method is refused';

	$c->notify('rpcswitch.ping');
	$r = $c->recv;
	is $r->{error}->{code}, -32000, 'ping is not a notification';
	ok !defined $r->{id}, 'ping notification is answered with a null id';

	is $c->call('rpcswitch.ping')->{result}, 'pong?',
		'the connection is still usable';
}

# a response to a call that was never made is ignored
{
	my $c = $sw->connect;
	$c->send({jsonrpc => '2.0', id => 'nosuchcall', result => 42});
	is $c->call('rpcswitch.ping')->{result}, 'pong?',
		'a stray response is ignored';
	like $sw->log, qr/response for unknown call nosuchcall/,
		'a stray response is logged';
}

# requests are pipelined, and answered in order
{
	my $c = $sw->connect;
	$c->send({jsonrpc => '2.0', id => $_, method => 'rpcswitch.ping', params => {}})
		for 1 .. 5;
	is_deeply [map { $c->recv->{id} } 1 .. 5], [1 .. 5],
		'pipelined requests are answered in order';
}

# netstrings may arrive in pieces
{
	my $c = $sw->connect;
	my $json = '{"jsonrpc":"2.0","id":"split","method":"rpcswitch.ping","params":{}}';
	$c->send_raw(length($json) . ':' . substr($json, 0, 20));
	$c->send_raw(substr($json, 20) . ',');
	is $c->recv->{id}, 'split', 'a netstring split across writes is reassembled';
}

# utf-8 survives the switch
{
	my $w = $sw->connect;
	$w->hello('theEmployee');
	$w->announce('bar.square');

	my $c = $sw->connect;
	$c->hello('deKlant');
	$c->send({
		jsonrpc => '2.0',
		id => 'utf8',
		method => 'foo.power',
		params => {name => "\x{263a} sm\x{ed}ley"},
	});

	my $req = $w->recv;
	is $req->{params}->{name}, "\x{263a} sm\x{ed}ley",
		'wide characters reach the worker intact';
	$w->respond($req, result => "\x{20ac}");
	is $c->recv->{result}, "\x{20ac}", 'wide characters come back intact';
}

is $sw->stop, 0, 'switch shut down';
