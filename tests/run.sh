#!/usr/bin/env bash
# Discover and run every test_*.sh file in this directory.
# Exit nonzero if any fail. Usage: bash tests/run.sh
set -u

cd "$(dirname "$0")"

shopt -s nullglob
files=(test_*.sh)
if [[ ${#files[@]} -eq 0 ]]; then
  echo "No test files found in tests/"
  exit 0
fi

failed=0
for f in "${files[@]}"; do
  echo "── $f ──"
  if ! bash "$f"; then
    failed=$((failed + 1))
  fi
  echo ""
done

total=${#files[@]}
if [[ $failed -eq 0 ]]; then
  echo "All $total test file(s) passed."
  exit 0
else
  echo "$failed of $total test file(s) failed."
  exit 1
fi
