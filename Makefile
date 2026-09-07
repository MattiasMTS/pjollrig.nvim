TESTS_INIT=tests/minit.lua

.PHONY: test test-unit test-integration

test:
	@scripts/test

test-unit:
	@scripts/test tests/pjollrig

test-integration:
	@scripts/test tests/integration
