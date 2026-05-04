CODEGEN_OUT = codegen/smithy-lua-codegen-test/build/smithyprojections/smithy-lua-codegen-test/source/lua-client-codegen

.PHONY: generate test test-runtime test-codegen protocoltest clean

generate:
	cd codegen && ./gradlew :smithy-lua-codegen-test:build
	rm -rf build
	cp -r runtime build
	cp -r $(CODEGEN_OUT)/* build/

test: test-runtime test-codegen

test-runtime: generate
	@for f in test/test_*.lua; do \
		echo "--- $$f ---"; \
		luajit "$$f" || exit 1; \
	done

test-codegen:
	cd codegen && ./gradlew build

PROTOCOLTEST_DIR = protocoltest/build/smithyprojections/protocoltest

protocoltest:
	cd codegen && ./gradlew :protocoltest:build
	@echo "\n=== Running protocol tests ==="
	@pass=0; fail=0; skip=0; \
	for proj in $(PROTOCOLTEST_DIR)/*/; do \
		codegen_dir=$$(find "$$proj" -name "lua-client-codegen" -type d 2>/dev/null | head -1); \
		[ -z "$$codegen_dir" ] && continue; \
		for f in $$codegen_dir/*/test_*.lua; do \
			[ -f "$$f" ] || continue; \
			result=$$(LUA_PATH="$$codegen_dir/?.lua;runtime/?.lua;runtime/?/init.lua;;" luajit "$$f" 2>&1); \
			p=$$(echo "$$result" | grep -c "^PASS:"); \
			s=$$(echo "$$result" | grep -c "^SKIP:"); \
			fl=$$(echo "$$result" | grep -c "^FAIL:"); \
			pass=$$((pass + p)); skip=$$((skip + s)); \
			if [ "$$fl" -gt 0 ]; then \
				fail=$$((fail + fl)); \
				echo "FAIL: $$(basename $$f): $$(echo "$$result" | grep "^FAIL:" | head -1)"; \
			fi; \
		done; \
	done; \
	echo "\nProtocol tests: $$pass passed, $$fail failed, $$skip skipped"

clean:
	rm -rf build
	cd codegen && ./gradlew clean
