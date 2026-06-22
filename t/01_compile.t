#!/usr/bin/env perl

# every module and the switch itself compile

use strict;
use warnings;

use Test::More;

use FindBin;
use lib "$FindBin::Bin/lib";
use TestSwitch;

my @modules = sort map { substr $_, length("$TestSwitch::ROOT/") }
	glob "$TestSwitch::ROOT/lib/RPC/Switch.pm $TestSwitch::ROOT/lib/RPC/Switch/*.pm $TestSwitch::ROOT/lib/RPC/Switch/Auth/*.pm";

plan tests => 1 + scalar @modules;

for my $file ('bin/rpcswitch', @modules) {
	my $out = qx{$^X -I$TestSwitch::ROOT/lib -c $TestSwitch::ROOT/$file 2>&1};
	is $?, 0, "$file compiles" or diag $out;
}
