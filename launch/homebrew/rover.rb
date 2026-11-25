# Homebrew cask for Rover. Publish in a tap repo named aluz123/homebrew-tap (Casks/rover.rb),
# then people install with:  brew install --cask aluz123/tap/rover
# Needs a notarized release (Homebrew rejects apps that Gatekeeper blocks).
# On each release: update version and sha256 (from dist/release/Rover-<version>.zip.sha256).
cask "rover" do
  version "1.0.0"
  sha256 "REPLACE_WITH_SHA256_OF_Rover-1.0.0.zip"

  url "https://github.com/aluz123/rover/releases/download/v#{version}/Rover-#{version}.zip"
  name "Rover"
  desc "Fast file search that understands plain English"
  homepage "https://github.com/aluz123/rover"

  depends_on macos: ">= :ventura"

  app "Rover.app"
  binary "#{appdir}/Rover.app/Contents/MacOS/Rover", target: "rover"

  zap trash: [
    "~/Library/Application Support/Rover",
    "~/Library/Preferences/com.alextowfigh.rover.plist",
  ]
end
