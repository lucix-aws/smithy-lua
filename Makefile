CODEGEN_TEST_BUILD = codegen/smithy-lua-codegen-test/build/smithyprojections/smithy-lua-codegen-test
PROTOCOLTEST_BUILD = codegen/protocol-test-codegen/build/smithyprojections/protocol-test-codegen

.PHONY: generate test test-runtime test-protocol clean

# Disable file insulation: busted's default insulate mode resets package.loaded
# between test files, forcing the teal loader to re-parse and re-compile every
# dependency (including the large schemas.tl) for each of the ~365 test files.
# Since protocol tests are stateless generated code this is safe to disable.
BUSTED = busted --no-auto-insulate

generate:
	cd codegen && ./gradlew clean :protocol-test-codegen:build
	rm -rf protocoltest
	mkdir -p protocoltest
	for proj in $(PROTOCOLTEST_BUILD)/*/; do \
		codegen_dir=$$(find "$$proj" -name "lua-client-codegen" -type d 2>/dev/null | head -1); \
		[ -z "$$codegen_dir" ] && continue; \
		cp -r "$$codegen_dir"/* protocoltest/ 2>/dev/null || true; \
	done

test: test-runtime test-protocol

test-runtime:
	$(BUSTED)

test-protocol:
	$(BUSTED) --run=protocol

clean:
	rm -rf build protocoltest
	cd codegen && ./gradlew clean
