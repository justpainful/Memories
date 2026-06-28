#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECTED_BUNDLE_ID="${EXPECTED_BUNDLE_ID:-space.hi.memories}"
IPA_PATH="${1:-}"

fail() {
  echo "verify_ipa.sh: $1" >&2
  exit 1
}

[[ -n "${IPA_PATH}" ]] || fail "Pass the path to the unsigned IPA as the first argument."
[[ -f "${IPA_PATH}" ]] || fail "IPA not found at ${IPA_PATH}."

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

unzip -q "${IPA_PATH}" -d "${WORK_DIR}"

APP_PATH="${WORK_DIR}/Payload/Memories.app"
INFO_PLIST="${APP_PATH}/Info.plist"

[[ -d "${APP_PATH}" ]] || fail "IPA does not contain Payload/Memories.app."
[[ -f "${INFO_PLIST}" ]] || fail "IPA bundle is missing Info.plist."
[[ ! -d "${APP_PATH}/PlugIns" ]] || fail "IPA unexpectedly contains extension payloads under PlugIns."
[[ ! -f "${APP_PATH}/embedded.mobileprovision" ]] || fail "Unsigned IPA should not contain an embedded.mobileprovision."

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${INFO_PLIST}" 2>/dev/null || true)"
APP_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "${INFO_PLIST}" 2>/dev/null || true)"
MARKETING_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO_PLIST}" 2>/dev/null || true)"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${INFO_PLIST}" 2>/dev/null || true)"
MINIMUM_OS="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "${INFO_PLIST}" 2>/dev/null || true)"

[[ "${BUNDLE_ID}" == "${EXPECTED_BUNDLE_ID}" ]] || fail "IPA bundle identifier is ${BUNDLE_ID:-<missing>}, expected ${EXPECTED_BUNDLE_ID}."
[[ "${APP_NAME}" == "Memories" ]] || fail "IPA app name is ${APP_NAME:-<missing>}, expected Memories."
[[ -n "${MARKETING_VERSION}" ]] || fail "IPA is missing CFBundleShortVersionString."
[[ -n "${BUILD_NUMBER}" ]] || fail "IPA is missing CFBundleVersion."
[[ "${MINIMUM_OS}" == 26.* ]] || fail "IPA MinimumOSVersion is ${MINIMUM_OS:-<missing>}, expected an iOS 26.x deployment target."

echo "IPA verified: ${IPA_PATH}"
