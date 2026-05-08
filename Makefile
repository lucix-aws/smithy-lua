CODEGEN_TEST_BUILD = codegen/smithy-lua-codegen-test/build/smithyprojections/smithy-lua-codegen-test
PROTOCOLTEST_BUILD = codegen/protocol-test-codegen/build/smithyprojections/protocol-test-codegen

BUSTED := $(shell test -x $$HOME/.luarocks/bin/busted && echo $$HOME/.luarocks/bin/busted || command -v busted 2>/dev/null)

.PHONY: generate test test-runtime test-codegen protocol-test unit clean teal-build

TL := $(shell command -v tl 2>/dev/null || echo $$HOME/.luarocks/bin/tl)

teal-build:
	@cd runtime && find smithy -name "*.tl" ! -name "*.d.tl" -print0 | while IFS= read -r -d '' f; do \
		$(TL) gen --gen-target=5.1 --gen-compat=off "$$f" -o "$${f%.tl}.lua" || exit 1; \
	done
	@echo "teal-build: done"

unit: $(BUSTED)

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
	$(BUSTED)

test-codegen:
	cd codegen && ./gradlew build

protocol-test:
	@echo "=== Running protocol tests ==="
	$(BUSTED) --run=protocol

endpoint-test:
	@echo "=== Running endpoint tests ==="
	$(BUSTED) --run=endpoint

clean:
	rm -rf build protocoltest
	cd codegen && ./gradlew clean
