#!/usr/bin/env perl

# starting, refusing to start, reloading and shutting down

use strict;
use warnings;

use Test::More;

use FindBin;
use lib "$FindBin::Bin/lib";
use TestSwitch;

plan tests => 19;

# a bad command line argument is fatal
{
	my $sw = TestSwitch->new;
	my ($status, $out) = $sw->run('--nosuchoption');
	isnt $status, 0, 'unknown option refused';
	like $out, qr/Error in command line arguments/,
		'unknown option gives a usage error';
}

# a missing config file is fatal
{
	my $sw = TestSwitch->new;
	unlink $sw->cfgdir . '/config.pl';
	my ($status, $out) = $sw->run;
	isnt $status, 0, 'missing config refused';
	like $out, qr/config\.pl/, 'missing config error names the config';
}

# an empty config file is fatal
{
	my $sw = TestSwitch->new(config => "\n");
	my ($status, $out) = $sw->run;
	isnt $status, 0, 'empty config refused';
	like $out, qr/empty config/,
		'empty config error complains about the config';
}

# a config without a method configuration is fatal
{
	my $sw = TestSwitch->new(config => "\$cfg = { listen => [] };\n");
	my ($status, $out) = $sw->run;
	isnt $status, 0, 'config without methods refused';
	like $out, qr/no method configuration/,
		'config without methods error complains about methods';
}

# a config without a listen section is fatal
{
	my $sw = TestSwitch->new(config => <<'EOF');
$cfg = {
	methods => 'methods.pl',
	auth => { password => 'RPC::Switch::Auth::Passwd' },
	'auth|password' => { pwfile => 'switch.passwd' },
};
EOF
	my ($status, $out) = $sw->run;
	isnt $status, 0, 'config without listen refused';
	like $out, qr/no listen configuration/,
		'config without listen error complains about listen';
}

# an incomplete method configuration is fatal
{
	my $sw = TestSwitch->new(methods => "\$methods = { foo => {} };\n");
	my ($status, $out) = $sw->run;
	isnt $status, 0, 'incomplete method config refused';
	like $out, qr/method config/,
		'incomplete method config error complains about it';
}

# a method mapped onto an acl that does not exist is fatal
{
	my $methods = $TestSwitch::METHODS;
	$methods =~ s/'foo\.div' => \['klant'\]/'foo.div' => ['nosuchacl']/
		or die 'method config not as expected';
	my $sw = TestSwitch->new(methods => $methods);
	my ($status, $out) = $sw->run;
	isnt $status, 0, 'unknown acl refused';
	like $out, qr/acl nosuchacl unknown for method foo\.div/,
		'unknown acl error names the acl';
}

# the normal case: it listens, reloads on sighup and exits on sigterm
{
	my $sw = TestSwitch->new->start;
	like $sw->log, qr/RPC::Switch starting work/, 'switch started';

	my $c = $sw->connect;
	$c->hello('deKlant');
	my $before = $c->call('rpcswitch.get_methods');
	is_deeply [sort map { keys %$_ } @{$before->{result}[1]}],
		[qw( foo.add foo.div foo.filtered foo.power )],
		'methods as configured';

	# reconfigure at runtime
	my $methods = $TestSwitch::METHODS;
	$methods =~ s/'power' => 'bar\.square',/'power' => 'bar.square',\n\t\t'extra' => 'bar.',/
		or die 'method config not as expected';
	$sw->write_methods($methods);
	$sw->hup;

	my $found = TestSwitch::wait_for(sub {
		my $r = $c->call('rpcswitch.get_methods');
		return scalar grep { $_->{'foo.extra'} } @{$r->{result}[1]};
	}, 10);
	ok $found, 'sighup reloaded the method config';

	is $sw->stop, 0, 'sigterm exits cleanly';
	like $sw->log, qr/caught sigTERM, shutting down/,
		'sigterm shutdown is logged';
}
