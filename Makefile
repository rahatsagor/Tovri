APP := build/Release/Tovri.app

.PHONY: build debug run test package icon clean

build:
	@scripts/build.sh

debug:
	@scripts/build.sh --debug

run: build
	@open $(APP)

test:
	@swift test

package: build
	@scripts/package.sh

icon:
	@swift scripts/make-icon.swift Resources/AppIcon.icns

clean:
	@rm -rf .build build dist
