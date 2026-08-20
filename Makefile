.PHONY: build test bundle verify install clean channel-isolation-test zsh-shim-test

VERSION ?= 0.1.0
BUILD ?= 1
DISTRIBUTION ?= 0
CODESIGN_IDENTITY ?= $(shell if [ "$(DISTRIBUTION)" = "1" ]; then pattern='Developer ID Application'; else pattern='Apple Development'; fi; security find-identity -v -p codesigning 2>/dev/null | awk -F '"' -v pattern="$$pattern" '$$0 ~ pattern {print $$2; exit}')
APP_BUNDLE := dist/myterm.app
INSTALL_BUNDLE := $(HOME)/Applications/myterm.app

build:
	swift build --product MyTerm --configuration release -Xswiftc -DMYTERM_PRODUCTION

test:
	swift test --parallel

channel-isolation-test:
	bash script/channel_isolation_test.sh

zsh-shim-test:
	bash script/zsh_shim_test.sh

bundle:
	MYTERM_VERSION="$(VERSION)" \
	MYTERM_BUILD="$(BUILD)" \
	MYTERM_DISTRIBUTION="$(DISTRIBUTION)" \
	CODESIGN_IDENTITY="$(CODESIGN_IDENTITY)" \
	./script/build_and_run.sh --prod --bundle

verify: bundle
	codesign --verify --deep --strict --verbose=2 $(APP_BUNDLE)
	plutil -lint $(APP_BUNDLE)/Contents/Info.plist

install: bundle
	pkill -x myterm >/dev/null 2>&1 || true
	mkdir -p $(HOME)/Applications
	ditto $(APP_BUNDLE) $(INSTALL_BUNDLE)

clean:
	rm -rf .build dist
