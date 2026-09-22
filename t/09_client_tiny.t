#!/usr/bin/env perl

# Tests: client-tiny against a live switch
#

use strict;
use warnings;

use Test::More;

use FindBin;
use lib "$FindBin::Bin/lib";
use TestSwitch;

BEGIN {
	# report why, so a missing dependency of the client is not
	# mistaken for the client itself being absent
	#
	unless (eval { require RPC::Switch::Client::Tiny; 1 }) {
		my $err = $@;
		$err =~ s/\n.*//s;
		plan skip_all => "RPC::Switch::Client::Tiny unusable: $err";
	}
}

use IO::Socket;
use POSIX ();

plan tests => 6;

diag "RPC::Switch::Client::Tiny $RPC::Switch::Client::Tiny::VERSION";

my $sw = TestSwitch->new->start;

sub rpcswitch_connect {
	my ($who) = @_;

	my $s = IO::Socket::INET->new(PeerAddr => '127.0.0.1:' . $sw->port, Proto => 'tcp', Timeout => 30) or die "connect failed: $@";

	return RPC::Switch::Client::Tiny->new(sock => $s, who => $who, token => $TestSwitch::PASSWORD, auth_method => 'password', timeout => 30);
}

# example worker
#
sub add_handler {
	my ($params, $rpcswitch) = @_;

	die "no addends\n" unless defined $params->{a};

	return {success => 1, sum => $params->{a} + $params->{b}, echo => $params->{echo}};
}

# the worker runs in a child: work() only returns on eof or stop
#
my $worker = fork;
die "fork failed: $!" unless defined $worker;
unless ($worker) {
	my $doc = {inputs => {a => 'an addend', b => 'an addend'}, outputs => {sum => 'the sum'}, description => 'add two numbers'};
	my $methods = {'bar.add' => {cb => \&add_handler, doc => $doc}};

	eval { rpcswitch_connect('theEmployee')->work('tinyworker', $methods) };
	POSIX::_exit(0); # skip the END blocks of the parent
}

# test worker announce
#
# watched with the raw client, so the test does not depend on the
# client module for both ends at once. get_clients names the worker,
# get_workers lists it by worker id only
#
my $mon = $sw->connect;
$mon->hello('deKlant');

sub tinyworker {
	my $clients = $mon->call('rpcswitch.get_clients')->{result}[1];
	my ($w) = grep { ($_->{workername} // '') eq 'tinyworker' } values %$clients;
	return $w;
}

ok(TestSwitch::wait_for(\&tinyworker, 20), "test tiny worker announce");
is_deeply(tinyworker()->{methods}, ['bar.add'], "test tiny worker method");

# test client call
#
my $client = rpcswitch_connect('deKlant');
my $res = $client->call('foo.add', {a => 2, b => 3, echo => "sm\x{ed}ley"});

is($res->{sum}, 5, "test tiny client result");
is($res->{echo}, "sm\x{ed}ley", "test tiny client utf8");

# test worker error
#
my $err;
unless (eval { $client->call('foo.add', {b => 1}); 1 }) { $err = $@; }

is(ref($err) && $err->{type}, 'worker', "test tiny client error type");
is($err->{text}, "no addends\n", "test tiny client error text");

kill 'TERM', $worker;
waitpid($worker, 0);
$sw->stop;
