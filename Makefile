.PHONY: build test bundle verify install clean channel-isolation-test zsh-shim-test ios-core-typecheck ui-test relay-test

VERSION ?= 0.1.0
BUILD ?= 1
DISTRIBUTION ?= 0
CODESIGN_IDENTITY ?= $(shell if [ "$(DISTRIBUTION)" = "1" ]; then pattern='Developer ID Application'; else pattern='Apple Development'; fi; security find-identity -v -p codesigning 2>/dev/null | awk -F '"' -v pattern="$$pattern" '$$0 ~ pattern {print $$2; exit}')
APP_BUNDLE := dist/myterm.app
INSTALL_BUNDLE := $(HOME)/Applications/myterm.app
BUNDLE_ID := com.gordonbeeming.myterm

build:
	swift build --product MyTerm --configuration release -Xswiftc -DMYTERM_PRODUCTION

test:
	swift test --parallel

channel-isolation-test:
	bash script/channel_isolation_test.sh

zsh-shim-test:
	bash script/zsh_shim_test.sh

ios-core-typecheck:
	bash script/ios_core_typecheck.sh

# Drives the companion app in the iOS Simulator against a live host. SIMULATOR names the device.
ui-test:
	bash script/ui_test.sh $(SIMULATOR)

# The relay's own protocol tests, then the Swift ends pushed through the real Worker running locally.
relay-test:
	cd relay && npm install --no-audit --no-fund && npm test
	swift test --filter RelayEndToEndTests

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
	# A hard kill skips applicationWillTerminate, where MyTerm writes its terminal snapshots
	# and agent sessions, so ask the app to quit itself and wait for it to finish.
	@osascript -e 'if application id "$(BUNDLE_ID)" is running then quit app id "$(BUNDLE_ID)"' >/dev/null 2>&1 || true
	@for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do \
		killall -s myterm >/dev/null 2>&1 || break; \
		sleep 1; \
	done
	mkdir -p $(HOME)/Applications
	# ditto merges into the destination, so a file the new bundle no longer ships would survive
	# and break the code signature it is not part of. Install into an empty directory.
	rm -rf $(INSTALL_BUNDLE)
	ditto $(APP_BUNDLE) $(INSTALL_BUNDLE)

clean:
	rm -rf .build dist
