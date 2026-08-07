.PHONY: lint
lint:
	swiftlint --strict

.PHONY: test
test:
	swift test

.PHONY: local
local:
	./scripts/build-release.sh

.PHONY: clean
clean:
	# Clean Xcode build folder
	xcodebuild clean -project ShareBeacon.xcodeproj -scheme ShareBeacon
	# Remove app preferences and state
	rm -rf ~/Library/Preferences/com.mjoe.sharebeacon.plist
	rm -rf ~/Library/Saved\ Application\ State/com.mjoe.sharebeacon.savedState
	# Reset defaults
	defaults delete com.mjoe.sharebeacon 2>/dev/null || true
	@echo "App has been reset to simulate a fresh installation"
	rm -rf build .build
