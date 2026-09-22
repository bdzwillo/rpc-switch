
# example config

$cfg = {
	# methods configuration file to load
	methods => 'methods.pl',
	listen => [
		{
			# display name for this local endpoint
			name => 'default port',
			# without an address mojo listens on all interfaces
			address => '127.0.0.1',
			# default value:
			#port => 6551,
			# auth => ['all'],
		},
		# a second endpoint, uncomment to enable tls
		#{
		#	address => '127.0.0.1',
		#	port => 6850,
		#	# adding a key enables tls
		#	tls_cert => 'rpcswitch.crt',
		#	tls_key => 'rpcswitch.pem',
		#	# adding a ca enables client certificate checking
		#	tls_ca => 'myCA.crt',
		#},
	],
	auth => {
		# authentication methods supported
		password => 'RPC::Switch::Auth::Password',
		#clientcert => 'RPC::Switch::Auth::ClientCert',
	},
	# per authentication method configuration
	'auth|password' => {
		pwfile => 'switch.passwd'
	},
	#'auth|clientcert' => {
	#	cnfile => 'switch.cnfile'
	#},
};

