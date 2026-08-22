.PHONY: build test lint fmt run-example npm-build npm-pack clean

build:
	zig build -Doptimize=ReleaseFast

npm-build:
	npm run build

npm-pack:
	npm pack

test:
	zig build test

lint: fmt
	zig build -Doptimize=Debug

fmt:
	zig fmt --check build.zig src tools

run-example:
	@zig build -Doptimize=ReleaseFast
	@./zig-out/bin/i18n-string-check ./testdata/locales/en.json ./testdata/src; status=$$?; test $$status -eq 1

clean:
	rm -rf zig-out .zig-cache dist
