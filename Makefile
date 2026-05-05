CODEGEN_TEST_BUILD = codegen/smithy-lua-codegen-test/build/smithyprojections/smithy-lua-codegen-test
PROTOCOLTEST_BUILD = codegen/protocol-test-codegen/build/smithyprojections/protocol-test-codegen

.PHONY: generate test test-runtime test-codegen protocol-test clean

generate:
	cd codegen && ./gradlew :smithy-lua-codegen-test:build :protocol-test-codegen:build
	rm -rf build
	cp -r runtime build
	@for proj in $(CODEGEN_TEST_BUILD)/*/; do \
		codegen_dir=$$(find "$$proj" -name "lua-client-codegen" -type d 2>/dev/null | head -1); \
		[ -z "$$codegen_dir" ] && continue; \
		cp -r "$$codegen_dir"/* build/ 2>/dev/null || true; \
	done
	rm -rf protocoltest
	@mkdir -p protocoltest
	@for proj in $(PROTOCOLTEST_BUILD)/*/; do \
		codegen_dir=$$(find "$$proj" -name "lua-client-codegen" -type d 2>/dev/null | head -1); \
		[ -z "$$codegen_dir" ] && continue; \
		cp -r "$$codegen_dir"/* protocoltest/ 2>/dev/null || true; \
	done

test: test-runtime test-codegen

test-runtime: generate
	@for f in test/test_*.lua; do \
		echo "--- $$f ---"; \
		luajit "$$f" || exit 1; \
	done

test-codegen:
	cd codegen && ./gradlew build

protocol-test:
	@echo "=== Running protocol tests ==="
	@pass=0; fail=0; skip=0; \
	for f in protocoltest/*/test_*.lua; do \
		[ -f "$$f" ] || continue; \
		result=$$(LUA_PATH="protocoltest/?.lua;runtime/?.lua;runtime/?/init.lua;runtime/smithy/?.lua;runtime/smithy/?/init.lua;;" luajit "$$f" 2>&1); \
		p=$$(echo "$$result" | grep -c "^PASS:"); \
		s=$$(echo "$$result" | grep -c "^SKIP:"); \
		fl=$$(echo "$$result" | grep -c "^FAIL:"); \
		pass=$$((pass + p)); skip=$$((skip + s)); \
		if [ "$$fl" -gt 0 ]; then \
			fail=$$((fail + fl)); \
			echo "FAIL: $$(basename $$f): $$(echo "$$result" | grep "^FAIL:" | head -1)"; \
		fi; \
	done; \
	echo "\nProtocol tests: $$pass passed, $$fail failed, $$skip skipped"

clean:
	rm -rf build protocoltest
	cd codegen && ./gradlew clean
