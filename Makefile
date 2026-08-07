.PHONY: test lint build clean

test:
	swift test

lint:
	swiftlint --strict

build:
	./scripts/build-release.sh

clean:
	rm -rf build .build
