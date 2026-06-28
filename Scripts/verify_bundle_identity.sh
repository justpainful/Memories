#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECTED_BUNDLE_ID="${EXPECTED_BUNDLE_ID:-space.hi.memories}"
IDENTITY_FILE="${ROOT_DIR}/Config/AppIdentity.xcconfig"
PROJECT_SPEC="${ROOT_DIR}/project.yml"
INFO_PLIST="${ROOT_DIR}/Sources/App/Info.plist"
DERIVED_APP_PATH="${BUILT_APP_PATH:-${ROOT_DIR}/build/DerivedData/Build/Products/Release-iphoneos/Memories.app}"
IPA_PATH="${IPA_PATH:-}"

fail() {
  echo "verify_bundle_identity.sh: $1" >&2
  exit 1
}

[[ -f "${IDENTITY_FILE}" ]] || fail "Missing ${IDENTITY_FILE}."
[[ -f "${PROJECT_SPEC}" ]] || fail "Missing ${PROJECT_SPEC}."
[[ -f "${INFO_PLIST}" ]] || fail "Missing ${INFO_PLIST}."

bundle_id_line="$(grep -E '^PRODUCT_BUNDLE_IDENTIFIER = ' "${IDENTITY_FILE}" || true)"
product_name_line="$(grep -E '^PRODUCT_NAME = ' "${IDENTITY_FILE}" || true)"

[[ "${bundle_id_line}" == "PRODUCT_BUNDLE_IDENTIFIER = ${EXPECTED_BUNDLE_ID}" ]] || fail "Config/AppIdentity.xcconfig must contain PRODUCT_BUNDLE_IDENTIFIER = ${EXPECTED_BUNDLE_ID}."
[[ "${product_name_line}" == "PRODUCT_NAME = Memories" ]] || fail "Config/AppIdentity.xcconfig must contain PRODUCT_NAME = Memories."

app_target_count="$(grep -c '^    type: application$' "${PROJECT_SPEC}" || true)"
[[ "${app_target_count}" == "1" ]] || fail "project.yml must define exactly one application target."
if grep -Eq '^    type: (app-extension|watchkit2-extension|messages-extension|tv-extension|sticker-pack-extension)$' "${PROJECT_SPEC}"; then
  fail "project.yml must not define any extension targets."
fi

grep -q '^name: Memories$' "${PROJECT_SPEC}" || fail "project.yml must keep the project name as Memories."
grep -q '^[[:space:]]\{4\}supportedDestinations:$' "${PROJECT_SPEC}" || fail "project.yml must declare supported destinations."
grep -q '^[[:space:]]\{6\}- iPhone$' "${PROJECT_SPEC}" || fail "project.yml must remain iPhone-only."
grep -q '^    PRODUCT_BUNDLE_IDENTIFIER: \$(PRODUCT_BUNDLE_IDENTIFIER)$' "${PROJECT_SPEC}" || fail "project.yml must flow PRODUCT_BUNDLE_IDENTIFIER through build settings."
grep -q '^    PRODUCT_NAME: \$(PRODUCT_NAME)$' "${PROJECT_SPEC}" || fail "project.yml must flow PRODUCT_NAME through build settings."

grep -q '<string>\$(PRODUCT_BUNDLE_IDENTIFIER)</string>' "${INFO_PLIST}" || fail "Sources/App/Info.plist must keep CFBundleIdentifier wired to PRODUCT_BUNDLE_IDENTIFIER."
grep -q '<string>\$(MARKETING_VERSION)</string>' "${INFO_PLIST}" || fail "Sources/App/Info.plist must keep CFBundleShortVersionString wired to MARKETING_VERSION."
grep -q '<string>\$(CURRENT_PROJECT_VERSION)</string>' "${INFO_PLIST}" || fail "Sources/App/Info.plist must keep CFBundleVersion wired to CURRENT_PROJECT_VERSION."

unexpected_bundle_ids="$(grep -RhoE '\b[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z0-9-]+){2,}\b' "${ROOT_DIR}" \
  --exclude-dir=.git \
  --exclude-dir=build \
  --exclude-dir=artifacts \
  --exclude='*.png' \
  --exclude='*.jpg' \
  --exclude='*.jpeg' \
  --exclude='*.xcresult' \
  | grep -v "^${EXPECTED_BUNDLE_ID}$" \
  | grep -v '^developer\.apple\.com$' \
  | grep -v '^openai\.com$' \
  | sort -u || true)"
[[ -z "${unexpected_bundle_ids}" ]] || fail "Unexpected bundle-like identifiers detected:\n${unexpected_bundle_ids}"

if [[ -d "${DERIVED_APP_PATH}" ]]; then
  built_info_plist="${DERIVED_APP_PATH}/Info.plist"
  [[ -f "${built_info_plist}" ]] || fail "Built app missing Info.plist at ${built_info_plist}."
  built_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${built_info_plist}" 2>/dev/null || true)"
  built_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "${built_info_plist}" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :CFBundleName' "${built_info_plist}" 2>/dev/null || true)"
  [[ "${built_bundle_id}" == "${EXPECTED_BUNDLE_ID}" ]] || fail "Built app bundle identifier is ${built_bundle_id:-<missing>}, expected ${EXPECTED_BUNDLE_ID}."
  [[ "${built_name}" == "Memories" ]] || fail "Built app display name is ${built_name:-<missing>}, expected Memories."
fi

if [[ -n "${IPA_PATH}" ]]; then
  "${ROOT_DIR}/Scripts/verify_ipa.sh" "${IPA_PATH}"
fi

echo "Bundle identity verified for ${EXPECTED_BUNDLE_ID}."
