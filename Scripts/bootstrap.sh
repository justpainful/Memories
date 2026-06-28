#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "bootstrap.sh: $1" >&2
  exit 1
}

if ! command -v xcodebuild >/dev/null 2>&1; then
  fail "Xcode command line tools are required. Install Xcode 26 and run 'xcode-select' before bootstrapping."
fi

if command -v xcodegen >/dev/null 2>&1; then
  echo "Using existing XcodeGen: $(xcodegen version)"
else
  if ! command -v brew >/dev/null 2>&1; then
    fail "XcodeGen is missing and Homebrew is unavailable. Install XcodeGen manually or provide Homebrew on the runner."
  fi

  echo "Installing XcodeGen with Homebrew..."
  brew install xcodegen
fi

mkdir -p "${ROOT_DIR}/build/logs" "${ROOT_DIR}/artifacts"
echo "Bootstrap complete."
