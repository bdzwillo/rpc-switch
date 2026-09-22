
# RPC-Switch

The RPC-Switch switches JSON-RPC 2.0 requests and responses between clients
and workers.

Features:
- Authenticated connections
	- Multiple authentication methods possible
- Fully asynchronous
- Method name mapping
- Runtime reconfigurable
- ACLs
	- Is a client allowed to call a method
	- Is a worker allowed to announce a method

## REQUIREMENTS

The dependencies are declared in the cpanfile and come from CPAN
(just cpanminus (packaged as perl-App-cpanminus in el9) has to be there):

make deps  - installs cpan modules in a self-contained tree under local/:.
make clean - removes local dependencies again.

To build an image "cpanm --installdeps ." would update the system root.

The rpc-switch itself needs no installing: bin/rpcswitch finds ../lib and
../etc relative to its binary and runs from wherever the tree is unpacked.

## TESTING

The test suite starts the switch on a private port and talks JSON-RPC to
it, so it needs the runtime requirements and Test::More:

make test - runs rpc-switch tests via "prove t"

Extra arguments might be passed like "make test PROVE_FLAGS='-v'".

Integration tests in t/09_client_tiny.t exercise the switch with the
RPC::Switch::Client::Tiny module, and are skipped without it.

make test DEVLIB=../rpc-switch-client-tiny/lib - test an unreleased client

## COPYRIGHT AND LICENSE

This software is copyright (c) 2017 by Wieger Opmeer.

This software is distributed under the Artistic License 2.0.

## ACKNOWLEDGEMENT

This software has been developed with support from STRATO <https://www.strato.com/>.  
In German: Diese Software wurde mit Unterstützung von STRATO <https://www.strato.de/> entwickelt.
