# Homebrew Cask submission template for ShareBeacon (official Homebrew).
#
# Validated locally: `brew style`, `brew audit --cask --online`,
# `brew livecheck`, `brew install --cask` / `brew uninstall --cask` all pass.
#
# To submit to the default Homebrew taps, add this as `Casks/s/sharebeacon.rb`
# in a PR to https://github.com/Homebrew/homebrew-cask once the repository
# meets the notability requirements (see Acceptable Casks).
# Commit message: `sharebeacon <version> (new cask)`

cask "sharebeacon" do
  version "1.0"
  sha256 "ef3b822851f02278b81d772afb6c5f01686741134da3e47328eee4215580a752"

  url "https://github.com/mjoe/sharebeacon/releases/download/v#{version}/ShareBeacon-#{version}.zip"
  name "ShareBeacon"
  desc "Keep SMB shares available and restore Finder sidebar favorites"
  homepage "https://github.com/mjoe/sharebeacon"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :tahoe

  app "ShareBeacon.app"

  zap trash: [
    "~/Library/Logs/sharebeacon.log",
    "~/Library/Preferences/org.mjoe.sharebeacon.plist",
  ]

  caveats <<~EOS
    ShareBeacon runs from the menu bar. Open Settings from the menu bar icon to
    configure SMB shares.
  EOS
end
