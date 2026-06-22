# install rpc-switch deps and run tests (the rpcswitch itself needs no build)
#
# $ make test PROVE_FLAGS='-v'
# $ make deps CPANM_FLAGS=--notest
# $ make deps LOCALLIB=/tmp/rpcswitch/perl5
#
CPANM = cpanm
CPANM_FLAGS =
PROVE = prove
LOCALLIB = local
PROVE_FLAGS =

# prepend $(LOCALLIB) - an inherited PERL5LIB has to survive.
# (perl drops an empty $(LOCALLIB) entry)
#
TEST_ENV = PERL5LIB=$(LOCALLIB)/lib/perl5:$$PERL5LIB

.PHONY: help have-cpanm deps test clean

help:
	@echo 'make deps   install the cpanfile dependencies into $(LOCALLIB)'
	@echo 'make test   run the test suite'
	@echo 'make clean  remove $(LOCALLIB)'

have-cpanm:
	@command -v $(CPANM) >/dev/null 2>&1 || { \
		echo '$(CPANM) not found. install perl-App-cpanminus, or:'; \
		echo '    curl -L https://cpanmin.us | perl - App::cpanminus'; \
		exit 1; \
	}

# --local-lib-contained ignores the non-core modules of the system perl, so
# the tree is complete wherever it was built. Satisfied deps are skipped.
#
deps: have-cpanm
	$(CPANM) $(CPANM_FLAGS) --installdeps --local-lib-contained=$(LOCALLIB) .

test:
	$(TEST_ENV) $(PROVE) $(PROVE_FLAGS) t

clean:
	rm -rf $(LOCALLIB)
