#!/usr/bin/env perl

# rpcswitch.announce and rpcswitch.withdraw, including backend filtering

use strict;
use warnings;

use Test::More;

use FindBin;
use lib "$FindBin::Bin/lib";
use TestSwitch;

plan tests => 25;

my $sw = TestSwitch->new->start;

# announcing a method the acl allows
{
	my $w = $sw->connect;
	$w->hello('theEmployee');

	my $r = $w->announce('bar.square', workername => 'squarer');
	ok $r->{result}[0], 'announce accepted';
	is $r->{result}[1]->{msg}, 'success', 'announce reports success';
	ok $r->{result}[1]->{worker_id}, 'announce returns a worker id';

	my $id = $r->{result}[1]->{worker_id};
	$r = $w->announce('bar.add');
	is $r->{result}[1]->{worker_id}, $id,
		'a second announce keeps the worker id';

	$r = $w->announce('bar.add');
	like $r->{error}->{message}, qr/already announced/,
		'announcing the same method twice fails';

	my $workers = $w->call('rpcswitch.get_workers')->{result}[1];
	is_deeply [sort @{$workers->{squarer}}], [qw( bar.add bar.square )],
		'both methods belong to the first workername';
}

# announce is refused when no acl allows it
{
	my $w = $sw->connect;
	$w->hello('deArbeider');

	my $r = $w->announce('bar.add');
	ok $r->{result}[0], 'deArbeider may announce bar.add';

	$r = $w->announce('bar.square');
	like $r->{error}->{message}, qr/does not allow announce of bar\.square/,
		'deArbeider may not announce bar.square';

	$r = $w->announce('nosuch.method');
	like $r->{error}->{message}, qr/no backend acl for nosuch\.method/,
		'a backend without an acl is refused';

	$r = $w->announce('nonamespace');
	like $r->{error}->{message}, qr/no namespace in nonamespace/,
		'a backend without a namespace is refused';

	$r = $w->call('rpcswitch.announce', {});
	like $r->{error}->{message}, qr/method required/, 'method is required';
}

# announce needs an authenticated connection
{
	my $c = $sw->connect;
	my $r = $c->announce('bar.add');
	is $r->{error}->{code}, -32002, 'announce before hello refused';
}

# a filtered backend insists on exactly one filter field
{
	my $w = $sw->connect;
	$w->hello('theEmployee');

	my $r = $w->announce('baz.filtered');
	like $r->{error}->{message}, qr/filtering is required for method baz\.filtered/,
		'filtering is required';

	$r = $w->announce('baz.filtered', filter => {other => 'x'});
	like $r->{error}->{message}, qr/not allowed on field other/,
		'filtering is allowed on the configured field only';

	$r = $w->announce('baz.filtered', filter => {tenant => undef});
	like $r->{error}->{message}, qr/undefined value/,
		'filtering requires a defined value';

	$r = $w->announce('baz.filtered', filter => {tenant => {a => 1}});
	like $r->{error}->{message}, qr/only allowed on simple values/,
		'filtering refuses a structure as value';

	$r = $w->announce('baz.filtered',
		filter => {tenant => 'acme'}, workername => 'acmeworker');
	ok $r->{result}[0], 'filtered announce accepted';

	my $workers = $w->call('rpcswitch.get_workers')->{result}[1];
	is_deeply $workers->{acmeworker}, [['baz.filtered', 'acme']],
		'get_workers reports the filter';
}

# an unfiltered backend refuses a filter
{
	my $w = $sw->connect;
	$w->hello('theEmployee');
	my $r = $w->announce('bar.add', filter => {tenant => 'acme'});
	like $r->{error}->{message}, qr/filtering not allowed for method bar\.add/,
		'filtering an unfiltered backend is refused';
}

# withdraw removes the method again
{
	my $w = $sw->connect;
	$w->hello('theEmployee');
	$w->announce('bar.square', workername => 'transient');
	$w->announce('baz.filtered',
		filter => {tenant => 'acme'}, workername => 'transient');

	my $r = $w->call('rpcswitch.withdraw', {method => 'bar.square'});
	is $r->{result}, 1, 'withdraw succeeds';

	my $workers = $w->call('rpcswitch.get_workers')->{result}[1];
	is_deeply $workers->{transient}, [['baz.filtered', 'acme']],
		'withdraw leaves the other method announced';

	$r = $w->call('rpcswitch.withdraw', {method => 'baz.square'});
	like $r->{error}->{message}, qr/unknown method/,
		'withdrawing what was never announced fails';

	$w->call('rpcswitch.withdraw', {method => 'baz.filtered'});
	$workers = $w->call('rpcswitch.get_workers')->{result}[1];
	ok !$workers->{transient}, 'the worker is gone after the last withdraw';
}

# disconnecting withdraws everything the worker announced
{
	my $w = $sw->connect;
	$w->hello('theEmployee');
	$w->announce('bar.square', workername => 'shortlived');
	$w->close;

	my $c = $sw->connect;
	$c->hello('deKlant');
	ok TestSwitch::wait_for(sub {
		my $workers = $c->call('rpcswitch.get_workers')->{result}[1];
		return !$workers->{shortlived};
	}, 10), 'a disconnect withdraws the announced methods';
}

is $sw->stop, 0, 'switch shut down';
