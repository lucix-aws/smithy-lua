CODEGEN_OUT = codegen/smithy-lua-codegen-test/build/smithyprojections/smithy-lua-codegen-test/source/lua-client-codegen

.PHONY: generate test test-runtime test-codegen clean

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

clean:
	rm -rf build
	cd codegen && ./gradlew clean
