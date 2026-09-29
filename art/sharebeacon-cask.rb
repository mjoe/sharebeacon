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
  version "0.10"
  sha256 "20e25e6b8ec166699f3d2cb1b04a7938c9ecfe7ee198a0dec57f4d66a0580205"

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
