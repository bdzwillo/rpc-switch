#!/usr/bin/env perl

# switching calls between a client and a worker

use strict;
use warnings;

use Test::More;

use FindBin;
use lib "$FindBin::Bin/lib";
use TestSwitch;

plan tests => 31;

my $sw = TestSwitch->new->start;

# a worker announcing $method, ready to be called
sub worker {
	my (@methods) = @_;
	my $w = $sw->connect;
	$w->hello('theEmployee');
	$w->announce($_) for @methods;
	return $w;
}

sub client {
	my $c = $sw->connect;
	$c->hello('deKlant');
	return $c;
}

# the round trip, with the configured name mapping
{
	my $w = worker('bar.square');
	my $c = client();

	$c->send({
		jsonrpc => '2.0',
		id => 'call1',
		method => 'foo.power',
		params => {n => 4},
	});

	my $req = $w->recv;
	is $req->{method}, 'bar.square', 'the call arrives under the backend name';
	is_deeply $req->{params}, {n => 4},
		'the call arrives with the parameters unchanged';
	is $req->{id}, 'call1', 'the call arrives under the id of the client';
	is $req->{rpcswitch}->{vcookie}, 'eatme',
		'the call carries channel information';
	is $req->{rpcswitch}->{who}, 'deKlant', 'the call names the caller';
	ok $req->{rpcswitch}->{vci}, 'the call carries a channel id';

	$w->respond($req, result => 16);
	my $res = $c->recv;
	is $res->{id}, 'call1', 'the answer comes back';
	is $res->{result}, 16, 'the answer carries the result of the worker';
	is $res->{rpcswitch}->{vci}, $req->{rpcswitch}->{vci},
		'the answer comes back over the same channel';
}

# errors travel the same way
{
	my $w = worker('bar.square');
	my $c = client();

	$c->send({jsonrpc => '2.0', id => 'e1', method => 'foo.power', params => {}});
	my $req = $w->recv;
	$w->respond($req, error => {code => -1, message => 'worker failed'});

	my $res = $c->recv;
	is $res->{id}, 'e1', 'the error comes back';
	is_deeply $res->{error}, {code => -1, message => 'worker failed'},
		'the error comes back unchanged';
}

# a notification is forwarded without an answer
{
	my $w = worker('bar.square');
	my $c = client();

	$c->notify('foo.power', {n => 2});
	my $req = $w->recv;
	is $req->{method}, 'bar.square', 'a notification is forwarded';
	ok !defined $req->{id}, 'a notification is forwarded without an id';
	ok $c->quiet, 'the client gets no answer to a notification';
}

# two clients on one worker keep their own channels
{
	my $w = worker('bar.square');
	my $c1 = client();
	my $c2 = client();

	$c1->send({jsonrpc => '2.0', id => 'a', method => 'foo.power', params => {n => 1}});
	my $r1 = $w->recv;
	$c2->send({jsonrpc => '2.0', id => 'b', method => 'foo.power', params => {n => 2}});
	my $r2 = $w->recv;

	isnt $r1->{rpcswitch}->{vci}, $r2->{rpcswitch}->{vci},
		'each client gets its own channel';

	# answer out of order
	$w->respond($r2, result => 'two');
	$w->respond($r1, result => 'one');
	is $c1->recv->{result}, 'one', 'the first client gets its own answer';
	is $c2->recv->{result}, 'two', 'the second client gets its own answer';
}

# without a worker there is nothing to switch to
{
	my $c = client();
	my $r = $c->call('foo.power', {n => 1});
	is $r->{error}->{code}, -32003, 'no worker for the backend';
	like $r->{error}->{message}, qr/No worker available for bar\.square/,
		'no worker error names the backend';
}

# the acl of the method is checked on every call
{
	my $w = worker('bar.add');
	my $c = $sw->connect;
	$c->hello('theEmployee');
	my $r = $c->call('foo.div', {a => 1});
	is $r->{error}->{code}, -32009, 'acl denies the call';
	like $r->{error}->{message}, qr/does not allow method foo\.div/,
		'acl error names the method';
}

# filtering picks the worker by a parameter of the call
{
	my $acme = $sw->connect;
	$acme->hello('theEmployee');
	$acme->announce('baz.filtered', filter => {tenant => 'acme'});

	my $c = client();

	my $r = $c->call('foo.filtered', {});
	is $r->{error}->{code}, -32010, 'the filter parameter is required';

	$r = $c->call('foo.filtered', {tenant => 'other'});
	is $r->{error}->{code}, -32003, 'no worker for an unknown filter value';

	$c->send({
		jsonrpc => '2.0',
		id => 'f1',
		method => 'foo.filtered',
		params => {tenant => 'acme'},
	});
	my $req = $acme->recv;
	is $req->{method}, 'baz.filtered', 'the matching worker is picked';
	$acme->respond($req, result => 'ok');
	is $c->recv->{result}, 'ok', 'the matching worker answers';
}

# a worker that disconnects takes its outstanding requests with it
{
	my $w = worker('bar.square');
	my $c = client();

	$c->send({jsonrpc => '2.0', id => 'gone', method => 'foo.power', params => {}});
	$w->recv;
	$w->close;

	my $err = $c->recv;
	is $err->{id}, 'gone', 'the outstanding request is answered';
	is $err->{error}->{code}, -32006,
		'the outstanding request fails with the worker gone';

	my $note = $c->recv;
	is $note->{method}, 'rpcswitch.channel_gone',
		'the channel is reported gone';
	ok $note->{params}->{channel}, 'the channel is reported by id';
}

# bad channel information is logged, the request dropped without an answer
{
	my $c = client();
	$c->send({
		jsonrpc => '2.0',
		id => 'badchan',
		method => 'foo.power',
		params => {},
		rpcswitch => {vcookie => 'notme', vci => 'x'},
	});
	ok TestSwitch::wait_for(sub {
		$sw->log =~ /invalid channel information from/
	}, 10), 'bad channel information is logged';
}

is $sw->stop, 0, 'switch shut down';
