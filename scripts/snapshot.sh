#!/bin/zsh
# Renders the search panel for a query to a PNG, using a second, short-lived Limelight process.
# usage: scripts/snapshot.sh "query" out.png
set -euo pipefail
LIMELIGHT_SNAPSHOT="$2" LIMELIGHT_QUERY="$1" "$HOME/Applications/Limelight.app/Contents/MacOS/Limelight"
