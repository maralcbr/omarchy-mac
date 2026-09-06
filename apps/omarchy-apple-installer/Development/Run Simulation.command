#!/bin/bash
# Explicit debug simulation launcher. No live-environment fallback.
set -euo pipefail
package_root=$(cd "$(dirname "$0")/.." && pwd)
if ! command -v xcodebuildmcp >/dev/null; then
  echo "XcodeBuildMCP is required. Install it before running this launcher." >&2
  exit 1
fi
xcodebuildmcp swift-package build --package-path "$package_root" --configuration debug
exec "$package_root/.build/debug/OmarchyAppleInstallerApp" --simulate
