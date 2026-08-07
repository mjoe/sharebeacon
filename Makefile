.PHONY: setup
setup:
	git config core.hooksPath .githooks
	bundle install

.PHONY: lint
lint:
	swiftlint --strict

# https://docs.fastlane.tools/getting-started/ios/setup/#use-a-gemfile
# https://docs.fastlane.tools/plugins/using-plugins/
# This may not work due to permissions, so use `$ fastlane update` which calls `brew` under the hood
.PHONY: update
update:
	sudo bundle update fastlane
	bundle exec fastlane update_plugins

.PHONY: test
test:
	swift test

.PHONY: local
local:
	./scripts/build-release.sh

.PHONY: beta
beta:
	bundle exec fastlane mac beta

.PHONY: prod
prod:
	bundle exec fastlane mac production

.PHONY: clean
clean:
	# Clean Xcode build folder
	xcodebuild clean -project jockey.xcodeproj -scheme ShareBeacon
	# Remove app preferences and state
		rm -rf ~/Library/Preferences/com.mjoe.sharebeacon.plist
		rm -rf ~/Library/Saved\ Application\ State/com.mjoe.sharebeacon.savedState
	# Reset defaults
	defaults delete com.mjoe.sharebeacon 2>/dev/null || true
	@echo "App has been reset to simulate a fresh installation"
	rm -rf build .build
