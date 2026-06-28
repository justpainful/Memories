#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC_PATH="${ROOT_DIR}/project.yml"
PROJECT_PATH="${ROOT_DIR}/Memories.xcodeproj"

fail() {
  echo "generate_project.sh: $1" >&2
  exit 1
}

if [[ ! -f "${SPEC_PATH}" ]]; then
  fail "Missing XcodeGen spec at ${SPEC_PATH}."
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  fail "XcodeGen is not installed. Run Scripts/bootstrap.sh first."
fi

pushd "${ROOT_DIR}" >/dev/null
xcodegen generate --spec "${SPEC_PATH}"
popd >/dev/null

if [[ ! -d "${PROJECT_PATH}" ]]; then
  fail "XcodeGen completed without creating ${PROJECT_PATH}."
fi

echo "Generated ${PROJECT_PATH}."
