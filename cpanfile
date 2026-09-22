# rpc-switch requirements
# install with something like:
# cpanm --installdeps .

requires 'CBOR::XS';

requires 'JSON::MaybeXS', '1.003008';

requires 'LMDB_File';

requires 'Mojolicious', '7.55';

requires 'MojoX::LineStream';

requires 'MojoX::NetstringStream', '0.05';

requires 'POSIX::RT::MQ', '0.04';

requires 'Ref::Util';

recommends 'Cpanel::JSON::XS', '2.3310';
recommends 'EV';
recommends 'IO::Socket::SSL', '1.94';
recommends 'Net::DNS::Native';
recommends 'RPC::Switch::Client', '0.14';

# required for tests when distributions split it from core perl
#
on test => sub {
	requires 'Test::More', '0.88';

	# t/09_client_tiny.t needs it, also to pull in JSON and
	# IO::Socket::SSL, which a DEVLIB checkout relies on.
	requires 'RPC::Switch::Client::Tiny', '1.67';
};
