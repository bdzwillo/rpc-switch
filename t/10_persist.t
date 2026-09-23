#!/usr/bin/env perl

# $backendpersist: the same value of a request field reaches the same worker

use strict;
use warnings;

use Test::More;

use FindBin;
use lib "$FindBin::Bin/lib";
use TestSwitch;

plan tests => 7;

my $sw = TestSwitch->new(methods => $TestSwitch::METHODS . <<'EOF')->start;

# calls to bar.* with a session_id parameter always go to the same worker
$backendpersist = {
	'bar.*' => 'session_id',
};
EOF

# two workers offering the same methods
my %workers = map {
	my $w = $sw->connect;
	$w->hello('theEmployee');
	$w->announce($_) for qw( bar.square bar.add );
	($_ => $w);
} qw( w1 w2 );

my $c = $sw->connect;
$c->hello('deKlant');

# call $method, answer it from whichever worker gets it; the name of
# that worker, or undef when none does
my $nextid = 1;
sub route {
	my ($method, $params) = @_;
	my $id = 'p' . $nextid++;
	$c->send({jsonrpc => '2.0', id => $id, method => $method,
		params => $params});
	my ($name, $req);
	TestSwitch::wait_for(sub {
		for (sort keys %workers) {
			next unless $req = $workers{$_}->recv(0.05);
			return $name = $_;
		}
		return;
	}, 10) or return;
	$workers{$name}->respond($req, result => $name);
	# skip notifications, like the channel_gone of a worker that left
	my $res;
	1 while ($res = $c->recv) and not defined $res->{id};
	return unless $res and $res->{id} eq $id;
	return $res->{result} eq $name ? $name : undef;
}

# the same session id, the same worker
{
	my %seen;
	$seen{route('foo.power', {session_id => 'r7'}) // 'none'}++ for 1 .. 10;
	is scalar(keys %seen), 1,
		'ten calls with one session id reach one worker';
	ok !$seen{none}, 'every call with a session id is answered';
}

# different session ids spread over the workers: the parity of str_hash() is
# the parity of the character sum, and r1 .. r10 give both odd and even ones
{
	my %seen;
	$seen{route('foo.power', {session_id => "r$_"}) // 'none'}++
		for 1 .. 10;
	is_deeply [sort keys %seen], [qw( w1 w2 )],
		'different session ids use both workers';
}

# a session id picks the same worker for every method the workers announced
{
	my @diff = grep {
		(route('foo.power', {session_id => "m$_"}) // '')
			ne (route('foo.add', {session_id => "m$_"}) // '-')
	} 1 .. 10;
	is scalar(@diff), 0,
		'a session id reaches the same worker for both methods';
}

# without the session id the call is dispatched as usual
{
	my $name = route('foo.power', {n => 2});
	ok $name, 'a call without a session id is answered';
}

# when a worker leaves, the other takes all session ids
{
	my $gone = route('foo.power', {session_id => 'r7'});
	my ($stays) = grep { $_ ne $gone } keys %workers;
	(delete $workers{$gone})->close;

	# a call sent before the switch has seen the disconnect is lost
	my $mon = $sw->connect;
	$mon->hello('deKlant');
	TestSwitch::wait_for(sub {
		keys %{$mon->call('rpcswitch.get_workers')->{result}[1]} == 1
	}, 10);
	is route('foo.power', {session_id => 'r7'}), $stays,
		'the remaining worker takes over the session id';
}

is $sw->stop, 0, 'switch shut down';
