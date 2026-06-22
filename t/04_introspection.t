#!/usr/bin/env perl

# the rpcswitch.get_* introspection methods

use strict;
use warnings;

use Test::More;

use FindBin;
use lib "$FindBin::Bin/lib";
use TestSwitch;

plan tests => 21;

my $sw = TestSwitch->new->start;

# get_methods is filtered by the acls of the caller
{
	my $c = $sw->connect;
	$c->hello('deKlant');
	my $r = $c->call('rpcswitch.get_methods');
	is $r->{result}[0], 'RES_OK', 'get_methods succeeds';
	my %m = map { %$_ } @{$r->{result}[1]};
	is_deeply [sort keys %m], [qw( foo.add foo.div foo.filtered foo.power )],
		'deKlant sees every method';
	is $m{'foo.div'}, 'divides dividend by divisor',
		'get_methods shows the configured description';
	is $m{'foo.add'}, 'undocumented method',
		'get_methods shows a placeholder for an undocumented method';

	my $c2 = $sw->connect;
	$c2->hello('theEmployee');
	my %m2 = map { %$_ } @{$c2->call('rpcswitch.get_methods')->{result}[1]};
	ok !exists $m2{'foo.div'}, 'theEmployee is not in acl klant';
	ok exists $m2{'foo.add'}, 'theEmployee still sees the public methods';
}

# get_method_details reports the backend and the acls
{
	my $c = $sw->connect;
	$c->hello('deKlant');

	my $r = $c->call('rpcswitch.get_method_details', {method => 'foo.power'});
	is $r->{result}[0], 'RES_OK', 'get_method_details succeeds';
	is $r->{result}[1]->{b}, 'bar.square',
		'get_method_details resolves the backend';
	is $r->{result}[1]->{msg}, 'no backend worker available',
		'get_method_details says there is no worker';

	$r = $c->call('rpcswitch.get_method_details', {method => 'foo.nosuch'});
	like $r->{error}->{message}, qr/method foo\.nosuch not found/,
		'unknown method rejected';

	$r = $c->call('rpcswitch.get_method_details', {});
	like $r->{error}->{message}, qr/method required/, 'method is required';

	my $c2 = $sw->connect;
	$c2->hello('theEmployee');
	$r = $c2->call('rpcswitch.get_method_details', {method => 'foo.div'});
	like $r->{error}->{message}, qr/does not allow calling of foo\.div/,
		'acl denies the details of foo.div';
}

# get_method_details picks up the documentation of the announced worker
{
	my $w = $sw->connect;
	$w->hello('theEmployee');
	$w->announce('bar.square', doc => 'squares its argument');

	my $c = $sw->connect;
	$c->hello('deKlant');
	my $r = $c->call('rpcswitch.get_method_details', {method => 'foo.power'});
	is $r->{result}[1]->{doc}, 'squares its argument',
		'documentation comes from the worker';
	ok !$r->{result}[1]->{msg},
		'no-worker message is gone once a worker announced';
}

# get_clients and get_workers list who is connected
{
	my $w = $sw->connect;
	$w->hello('theEmployee');
	my $id = $w->announce('bar.add', workername => 'adder')
		->{result}[1]->{worker_id};

	my $c = $sw->connect;
	$c->hello('deKlant');

	my $clients = $c->call('rpcswitch.get_clients')->{result}[1];
	my ($worker) = grep { ($_->{workername} // '') eq 'adder' } values %$clients;
	ok $worker, 'get_clients lists the worker';
	is $worker->{localname}, 'test',
		'get_clients lists the worker on the configured listener';
	is $worker->{who}, 'theEmployee',
		'get_clients lists the worker under its own name';
	is_deeply $worker->{methods}, ['bar.add'],
		'get_clients lists the methods of the worker';

	my $workers = $c->call('rpcswitch.get_workers')->{result}[1];
	is_deeply $workers->{$id}, ['bar.add'],
		'get_workers lists the method under the worker id';
}

# get_stats answers; v2 fills in the counters every 60 seconds
{
	my $c = $sw->connect;
	$c->hello('deKlant');
	my $r = $c->call('rpcswitch.get_stats');
	is $r->{result}[0], 'RES_OK', 'get_stats succeeds';
}

is $sw->stop, 0, 'switch shut down';
