#!/bin/bash
# Makes this Mac a Forgejo Actions runner (label macos-arm64, host mode)
# for git.aza.network, started at login.
#
#   release/runner.sh <registration token>
#
# The token comes from git.aza.network › the aza organisation › Settings ›
# Actions › Runners › Create new runner, so every aza repo can use it.
set -euo pipefail
TOKEN="${1:?registration token}"
DIR="$HOME/.forgejo-runner"
PLIST="$HOME/Library/LaunchAgents/network.aza.forgejo-runner.plist"
RUNNER="$(command -v forgejo-runner || echo /opt/homebrew/bin/forgejo-runner)"
[ -x "$RUNNER" ] || brew install forgejo-runner

mkdir -p "$DIR"
cd "$DIR"
"$RUNNER" generate-config > config.yaml
"$RUNNER" register --no-interactive --instance https://git.aza.network --token "$TOKEN" \
  --name "$(scutil --get LocalHostName)" --labels macos-arm64:host --config config.yaml

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>network.aza.forgejo-runner</string>
  <key>ProgramArguments</key><array><string>$RUNNER</string><string>daemon</string><string>--config</string><string>$DIR/config.yaml</string></array>
  <key>WorkingDirectory</key><string>$DIR</string>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$DIR/runner.log</string>
  <key>StandardErrorPath</key><string>$DIR/runner.log</string>
</dict>
</plist>
PLIST
launchctl bootout "gui/$(id -u)/network.aza.forgejo-runner" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Runner registered and running; log at $DIR/runner.log"
