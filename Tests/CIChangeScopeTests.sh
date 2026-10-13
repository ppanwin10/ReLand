#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CLASSIFIER="$ROOT/Scripts/classify-ci-changes"

expect_scope() {
  expected=$1
  name=$2
  shift 2

  actual=$(printf '%s\n' "$@" | "$CLASSIFIER")
  if [ "$actual" != "$expected" ]; then
    echo "Expected $expected CI scope for $name, got $actual" >&2
    exit 1
  fi
}

expect_scope \
  "docs-only" \
  "documentation files" \
  "README.md" \
  "docs/RELEASE.md" \
  "docs/privacy.html" \
  "docs/.nojekyll" \
  ".gitignore"

expect_scope \
  "full" \
  "application source" \
  "Apps/ReLandClient/App/ReLandApp.swift"

expect_scope \
  "full" \
  "workflow policy" \
  ".github/workflows/ci.yml"

expect_scope \
  "full" \
  "mixed documentation and source" \
  "CHANGELOG.md" \
  "Packages/ReLandCore/Sources/ReLandCore/WireProtocol.swift"

actual=$(printf '' | "$CLASSIFIER")
if [ "$actual" != "full" ]; then
  echo "Expected full CI scope for an empty change list, got $actual" >&2
  exit 1
fi

echo "CI change scope tests passed."
