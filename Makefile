.PHONY: build test lint run-example npm-build npm-pack

build:
	go build ./cmd/i18n-string-check

npm-build:
	npm run build

npm-pack:
	npm pack

test:
	go test ./...

lint:
	go vet ./...

run-example:
	@go build -o /tmp/i18n-string-check-example ./cmd/i18n-string-check
	@/tmp/i18n-string-check-example ./testdata/locales/en.json ./testdata/src; status=$$?; test $$status -eq 1
