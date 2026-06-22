package TestSwitch;

# generates a configuration directory, starts bin/rpcswitch on a private
# port and hands out clients speaking JSON-RPC 2.0 over netstrings.
#

use strict;
use warnings;

use Test::More ();

BEGIN {
	my @missing = grep { not eval "require $_; 1" }
		qw(Mojolicious MojoX::NetstringStream JSON::MaybeXS);
	Test::More::plan(
		skip_all => 'missing prerequisites (run "make deps"): '
			. join(', ', @missing)
	) if @missing;
	JSON::MaybeXS->import(qw(decode_json encode_json));
}

use Cwd qw(realpath);
use File::Temp qw(tempdir);
use FindBin;
use IO::Select;
use IO::Socket::INET;
use POSIX qw(WNOHANG);
use Time::HiRes qw(sleep time);

our $ROOT = realpath("$FindBin::Bin/..");
our $BIN = "$ROOT/bin/rpcswitch";

# tests write to connections that the switch may already have closed
$SIG{PIPE} = 'IGNORE';

# the password all generated accounts share
our $PASSWORD = 'secret';

# acls: theEmployee in bar and addbar, deArbeider in addbar, deKlant in
# klant, everyone in public
#
our $METHODS = <<'EOF';
$methods = {
	'foo' => {
		'power' => 'bar.square',
		'add' => 'bar.',
		'div' => {
			b => 'bar.',
			c => 'you@example.com',
			d => 'divides dividend by divisor',
		},
		'filtered' => 'baz.',
	},
};

$acl = {
	'addbar' => ['+bar', 'deArbeider'],
	'bar' => [qw( theEmployee )],
	'klant' => [qw( deKlant )],
	'public' => '*',
};

$method2acl = {
	'foo.div' => ['klant'],
	'foo.*' => 'public',
};

$backend2acl = {
	'bar.add' => 'addbar',
	'bar.*' => 'bar',
	'baz.*' => 'bar',
};

$backendfilter = {
	'baz.filtered' => 'tenant',
};
EOF

our @USERS = qw( theEmployee deArbeider deKlant );

my @running;

END { $_->stop for splice @running }

# prepare a configuration directory; start nothing.
#
#	config	config.pl contents, default generated
#	methods	methods.pl contents, default $METHODS
#	users	account names, default @USERS
#	port	listen port, default a free one
#	listen	extra key/values for the default listen entry
#
sub new {
	my ($class, %args) = @_;

	my $self = bless {
		dir => tempdir('rpcswitch-XXXXXXXX', TMPDIR => 1, CLEANUP => 1),
		methods => $args{methods} // $METHODS,
		users => $args{users} // \@USERS,
		autoport => !$args{port},
		port => $args{port} // _free_port(),
		listen => $args{listen} // {},
		config => $args{config},
	}, $class;

	mkdir $self->cfgdir or die 'no cfgdir: ' . $!;
	$self->write_methods($self->{methods});
	$self->_write_passwd;
	$self->_write_config;

	return $self;
}

sub dir { $_[0]->{dir} }
sub cfgdir { $_[0]->{dir} . '/etc' }
sub logfile { $_[0]->{dir} . '/rpcswitch.log' }
sub pid { $_[0]->{pid} }
sub port { $_[0]->{port} }

# everything the switch wrote to stdout and stderr so far
sub log {
	my ($self) = @_;
	open my $fh, '<', $self->logfile or return '';
	local $/;
	my $log = <$fh>;
	close $fh;
	return $log // '';
}

sub write_methods {
	my ($self, $methods) = @_;
	_spew($self->cfgdir . '/methods.pl', $methods);
	return $self;
}

sub _write_passwd {
	my ($self) = @_;
	# crypt(3) sha-256, the only format Auth::Passwd accepts
	_spew($self->cfgdir . '/switch.passwd', join '',
		map { "$_:" . crypt($PASSWORD, '$5$rpcswitch$') . "\n" }
			@{$self->{users}});
}

sub _write_config {
	my ($self) = @_;
	my $config = $self->{config} // do {
		my $extra = join '', map { "\t\t\t$_ => '$self->{listen}->{$_}',\n" }
			sort keys %{$self->{listen}};
		<<"EOF";
\$cfg = {
	methods => 'methods.pl',
	listen => [
		{
			name => 'test',
			address => '127.0.0.1',
			port => $self->{port},
$extra		},
	],
	auth => {
		password => 'RPC::Switch::Auth::Passwd',
	},
	'auth|password' => {
		pwfile => 'switch.passwd',
	},
};
EOF
	};
	_spew($self->cfgdir . '/config.pl', $config);
}

# run in the background, wait for the listen socket
sub start {
	my ($self) = @_;

	for (1 .. 3) {
		$self->_write_config;
		$self->{pid} = _spawn($self->logfile, $BIN,
			'--cfgdir', $self->cfgdir, '--cfgfile', 'config.pl');
		if ($self->_wait_listen(30)) {
			push @running, $self;
			return $self;
		}
		$self->stop;
		# the port may have been taken between picking and binding
		last unless $self->{autoport};
		$self->{port} = _free_port();
	}

	Test::More::BAIL_OUT('rpcswitch did not start: ' . $self->log);
}

# terminate and return the wait status
sub stop {
	my ($self) = @_;
	my $pid = delete $self->{pid} or return;
	@running = grep { $_ != $self } @running;
	kill 'TERM', $pid;
	my $status = _wait_exit($pid, 10);
	unless (defined $status) {
		kill 'KILL', $pid;
		$status = _wait_exit($pid, 10);
	}
	return $status;
}

sub hup {
	my ($self) = @_;
	kill 'HUP', $self->{pid} or die 'no switch to signal';
	return $self;
}

# run in the foreground until it exits, for the cases where it is
# expected to refuse to start. returns the wait status and the output.
#
sub run {
	my ($self, @argv) = @_;
	@argv = ('--cfgdir', $self->cfgdir, '--cfgfile', 'config.pl')
		unless @argv;
	my $pid = _spawn($self->logfile, $BIN, @argv);
	my $status = _wait_exit($pid, 30);
	unless (defined $status) {
		kill 'KILL', $pid;
		_wait_exit($pid, 10);
		return (undef, $self->log);
	}
	return ($status, $self->log);
}

# a client connection with the greetings already read
sub connect {
	my ($self) = @_;
	return TestSwitch::Conn->new($self->port);
}

# poll $cb until it returns true or $timeout seconds pass
sub wait_for {
	my ($cb, $timeout) = @_;
	my $deadline = time + ($timeout // 10);
	while (time < $deadline) {
		my $r = $cb->();
		return $r if $r;
		sleep 0.05;
	}
	return;
}

sub _wait_listen {
	my ($self, $timeout) = @_;
	return wait_for(sub {
		return 0 if defined _wait_exit($self->{pid}, 0);
		my $s = IO::Socket::INET->new(
			PeerAddr => '127.0.0.1',
			PeerPort => $self->{port},
			Proto => 'tcp',
		) or return 0;
		close $s;
		return 1;
	}, $timeout);
}

sub _spawn {
	my ($logfile, @argv) = @_;
	my $pid = fork;
	die "fork failed: $!" unless defined $pid;
	return $pid if $pid;
	open STDIN, '<', '/dev/null' or die $!;
	open STDOUT, '>>', $logfile or die $!;
	open STDERR, '>&', \*STDOUT or die $!;
	exec $^X, @argv;
	die "exec failed: $!";
}

# reap $pid; its wait status, or undef on timeout
sub _wait_exit {
	my ($pid, $timeout) = @_;
	my $deadline = time + $timeout;
	while (1) {
		my $r = waitpid $pid, WNOHANG;
		return $? if $r == $pid;
		return -1 if $r == -1; # already reaped
		return undef if time >= $deadline;
		sleep 0.05;
	}
}

sub _free_port {
	my $s = IO::Socket::INET->new(
		LocalAddr => '127.0.0.1',
		Proto => 'tcp',
		Listen => 1,
	) or die "no free port: $!";
	my $port = $s->sockport;
	close $s;
	return $port;
}

sub _spew {
	my ($path, $data) = @_;
	open my $fh, '>', $path or die "cannot write $path: $!";
	print $fh $data;
	close $fh or die "cannot write $path: $!";
}

package TestSwitch::Conn;

# a blocking netstring JSON-RPC client. it checks no framing itself, so
# the tests can send malformed input to the switch.
#

use strict;
use warnings;

use IO::Select;
use IO::Socket::INET;
use JSON::MaybeXS qw(decode_json encode_json);

# waiting for a message that should arrive, and for one that should not
use constant TIMEOUT => 10;
use constant QUIET => 0.5;

sub new {
	my ($class, $port) = @_;
	my $socket = IO::Socket::INET->new(
		PeerAddr => '127.0.0.1',
		PeerPort => $port,
		Proto => 'tcp',
	) or die "cannot connect to port $port: $!";
	my $self = bless {
		buf => '',
		eof => 0,
		nextid => 1,
		select => IO::Select->new($socket),
		socket => $socket,
	}, $class;
	$self->{greetings} = $self->recv;
	return $self;
}

sub greetings { $_[0]->{greetings} }
sub eof { $_[0]->{eof} }

# the next decoded message, or undef on timeout or eof
sub recv {
	my ($self, $timeout) = @_;
	$timeout //= TIMEOUT;
	while (1) {
		if ($self->{buf} =~ /^(\d+):/) {
			my ($len, $off) = ($1, length($1) + 1);
			if (length($self->{buf}) >= $off + $len + 1) {
				my $chunk = substr $self->{buf}, $off, $len;
				substr $self->{buf}, 0, $off + $len + 1, '';
				return decode_json($chunk);
			}
		}
		return undef if $self->{eof};
		return undef unless $self->{select}->can_read($timeout);
		my $n = sysread $self->{socket}, my $bytes, 65536;
		unless ($n) {
			$self->{eof} = 1;
			return undef;
		}
		$self->{buf} .= $bytes;
	}
}

# true when nothing more arrives and the connection stays open
sub quiet {
	my ($self) = @_;
	return !defined($self->recv(QUIET)) && !$self->{eof};
}

# true when the switch closed the connection, once input is drained
sub closed {
	my ($self, $timeout) = @_;
	1 while defined $self->recv($timeout // QUIET);
	return $self->{eof};
}

sub send_raw {
	my ($self, $bytes) = @_;
	my $socket = $self->{socket};
	print $socket $bytes;
	return $self;
}

sub send {
	my ($self, $obj) = @_;
	my $json = encode_json($obj);
	use bytes;
	return $self->send_raw(length($json) . ':' . $json . ',');
}

sub notify {
	my ($self, $method, $params) = @_;
	return $self->send({
		jsonrpc => '2.0',
		method => $method,
		params => $params // {},
	});
}

# send a request, return the next message (its response, normally)
sub call {
	my ($self, $method, $params, %opts) = @_;
	my $id = $opts{id} // 'r' . $self->{nextid}++;
	$self->send({
		jsonrpc => '2.0',
		id => $id,
		method => $method,
		params => $params // {},
		($opts{rpcswitch} ? (rpcswitch => $opts{rpcswitch}) : ()),
	});
	return $self->recv($opts{timeout});
}

# answer a request forwarded by the switch, keeping its channel
sub respond {
	my ($self, $request, %args) = @_;
	return $self->send({
		jsonrpc => '2.0',
		rpcswitch => $request->{rpcswitch},
		id => $request->{id},
		(exists $args{error}
			? (error => $args{error})
			: (result => $args{result})),
	});
}

sub hello {
	my ($self, $who, %args) = @_;
	return $self->call('rpcswitch.hello', {
		who => $who,
		method => $args{method} // 'password',
		token => $args{token} // $TestSwitch::PASSWORD,
	});
}

sub announce {
	my ($self, $method, %args) = @_;
	return $self->call('rpcswitch.announce', {method => $method, %args});
}

sub close {
	my ($self) = @_;
	CORE::close delete $self->{socket} if $self->{socket};
	$self->{eof} = 1;
	return;
}

sub DESTROY { $_[0]->close }

1;
