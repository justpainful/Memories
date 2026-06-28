#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="${ROOT_DIR}/build/DerivedData"
RESULTS_PATH="${ROOT_DIR}/build/results"
LOGS_PATH="${ROOT_DIR}/build/logs"
ARTIFACTS_PATH="${ROOT_DIR}/artifacts"
APP_PATH="${DERIVED_DATA_PATH}/Build/Products/Release-iphoneos/Memories.app"

fail() {
  echo "build_unsigned_ipa.sh: $1" >&2
  exit 1
}

mkdir -p "${DERIVED_DATA_PATH}" "${RESULTS_PATH}" "${LOGS_PATH}" "${ARTIFACTS_PATH}"

[[ -d "${ROOT_DIR}/Memories.xcodeproj" ]] || fail "Memories.xcodeproj is missing. Run Scripts/generate_project.sh first."

BUILD_LOG="${LOGS_PATH}/unsigned-ipa-build.log"
RESULT_BUNDLE="${RESULTS_PATH}/Memories-build.xcresult"

rm -rf "${APP_PATH}" "${RESULT_BUNDLE}" "${ARTIFACTS_PATH}/Payload"

set -o pipefail
xcodebuild \
  -project "${ROOT_DIR}/Memories.xcodeproj" \
  -scheme Memories \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  -resultBundlePath "${RESULT_BUNDLE}" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  clean build | tee "${BUILD_LOG}"
set +o pipefail

[[ -d "${APP_PATH}" ]] || fail "Expected built app at ${APP_PATH}, but the generic iPhone device build did not produce it."

INFO_PLIST="${APP_PATH}/Info.plist"
[[ -f "${INFO_PLIST}" ]] || fail "Built app is missing ${INFO_PLIST}."

MARKETING_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO_PLIST}" 2>/dev/null || true)"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${INFO_PLIST}" 2>/dev/null || true)"

[[ -n "${MARKETING_VERSION}" ]] || fail "Unable to read CFBundleShortVersionString from the built app."
[[ -n "${BUILD_NUMBER}" ]] || fail "Unable to read CFBundleVersion from the built app."

PAYLOAD_DIR="${ARTIFACTS_PATH}/Payload"
IPA_BASENAME="Memories-${MARKETING_VERSION}-${BUILD_NUMBER}-unsigned"
IPA_PATH="${ARTIFACTS_PATH}/${IPA_BASENAME}.ipa"
CHECKSUM_PATH="${ARTIFACTS_PATH}/${IPA_BASENAME}.sha256"
MANIFEST_PATH="${ARTIFACTS_PATH}/${IPA_BASENAME}.manifest.json"

mkdir -p "${PAYLOAD_DIR}"
cp -R "${APP_PATH}" "${PAYLOAD_DIR}/Memories.app"

pushd "${ARTIFACTS_PATH}" >/dev/null
rm -f "${IPA_PATH}" "${CHECKSUM_PATH}" "${MANIFEST_PATH}"
ditto -c -k --sequesterRsrc --keepParent "Payload" "${IPA_PATH}"
popd >/dev/null

shasum -a 256 "${IPA_PATH}" > "${CHECKSUM_PATH}"
CHECKSUM_VALUE="$(awk '{print $1}' "${CHECKSUM_PATH}")"
GIT_SHA="$(git -C "${ROOT_DIR}" rev-parse HEAD 2>/dev/null || echo "unknown")"
BUILD_TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

cat > "${MANIFEST_PATH}" <<EOF
{
  "app_name": "Memories",
  "bundle_identifier": "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${INFO_PLIST}")",
  "display_name": "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "${INFO_PLIST}" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :CFBundleName' "${INFO_PLIST}")",
  "marketing_version": "${MARKETING_VERSION}",
  "build_number": "${BUILD_NUMBER}",
  "git_sha": "${GIT_SHA}",
  "build_timestamp": "${BUILD_TIMESTAMP}",
  "sha256": "${CHECKSUM_VALUE}",
  "ipa_filename": "$(basename "${IPA_PATH}")",
  "checksum_filename": "$(basename "${CHECKSUM_PATH}")",
  "build_log": "$(basename "${BUILD_LOG}")"
}
EOF

"${ROOT_DIR}/Scripts/verify_ipa.sh" "${IPA_PATH}"

echo "Unsigned IPA created at ${IPA_PATH}."
