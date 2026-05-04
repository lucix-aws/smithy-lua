CODEGEN_OUT = codegen/smithy-lua-codegen-test/build/smithyprojections/smithy-lua-codegen-test/source/lua-client-codegen
PROTOCOLTEST_BUILD = protocoltest/build/smithyprojections/protocoltest

.PHONY: generate test test-runtime test-codegen protocol-test clean

generate:
	cd codegen && ./gradlew :smithy-lua-codegen-test:build :protocoltest:build
	rm -rf build
	cp -r runtime build
	cp -r $(CODEGEN_OUT)/* build/
	rm -rf protocoltest/out
	@mkdir -p protocoltest/out
	@for proj in $(PROTOCOLTEST_BUILD)/*/; do \
		codegen_dir=$$(find "$$proj" -name "lua-client-codegen" -type d 2>/dev/null | head -1); \
		[ -z "$$codegen_dir" ] && continue; \
		cp -r "$$codegen_dir"/* protocoltest/out/ 2>/dev/null || true; \
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
	for f in protocoltest/out/*/test_*.lua; do \
		[ -f "$$f" ] || continue; \
		result=$$(LUA_PATH="protocoltest/out/?.lua;runtime/smithy/?.lua;runtime/smithy/?/init.lua;;" luajit "$$f" 2>&1); \
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
	rm -rf build protocoltest/out
	cd codegen && ./gradlew clean
