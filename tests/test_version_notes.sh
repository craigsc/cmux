#!/usr/bin/env bash
# Tests for cmux version notes.
# Run: bash tests/test_version_notes.sh

set -u

CMUX_SH="$(cd "$(dirname "$0")/.." && pwd)/cmux.sh"
SAMPLE_NOTES='## 0.1.3
- Branch from the repo default branch
- New --from flag

## 0.1.2
- Older change'

fails=0
passes=0

# Run $* in an isolated $HOME with a fake VERSION + NOTES.md so we never
# touch the real ~/.cmux.
isolated() {
  local fake_version="$1"; shift
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/.cmux"
  printf '%s' "$fake_version" > "$tmp/.cmux/VERSION"
  printf '%s\n' "$SAMPLE_NOTES" > "$tmp/.cmux/NOTES.md"
  HOME="$tmp" bash -c "source '$CMUX_SH' 2>/dev/null; $*"
  local rc=$?
  rm -rf "$tmp"
  return $rc
}

# Same, but with NOTES.md removed before the test body runs.
isolated_no_notes() {
  local fake_version="$1"; shift
  isolated "$fake_version" 'rm -f "$HOME/.cmux/NOTES.md"; '"$*"
}

check() {
  local desc="$1"; shift
  if "$@"; then
    printf '  ok   %s\n' "$desc"
    passes=$((passes + 1))
  else
    printf '  FAIL %s\n' "$desc"
    fails=$((fails + 1))
  fi
}

# ── _cmux_version_notes ──
check "_cmux_version_notes returns the current version's section" \
  isolated 0.1.3 '[[ "$(_cmux_version_notes)" == *"--from flag"* ]]'

check "_cmux_version_notes ignores other versions' sections" \
  isolated 0.1.3 '[[ "$(_cmux_version_notes)" != *"Older change"* ]]'

check "_cmux_version_notes returns nonzero when current version has no notes" \
  isolated 999.0.0 '! _cmux_version_notes >/dev/null 2>&1'

check "_cmux_version_notes fails gracefully when NOTES.md is missing" \
  isolated_no_notes 0.1.3 '! _cmux_version_notes >/dev/null 2>&1'

# ── cmux version ──
check "cmux version prints version string" \
  isolated 0.1.3 'echo 0.1.3 > "$HOME/.cmux/.last_seen_version"; [[ "$(cmux version 2>&1)" == *"cmux 0.1.3"* ]]'

check "cmux version prints notes when they exist" \
  isolated 0.1.3 'echo 0.1.3 > "$HOME/.cmux/.last_seen_version"; [[ "$(cmux version 2>&1)" == *"--from flag"* ]]'

check "cmux version works even when NOTES.md is missing" \
  isolated_no_notes 0.1.3 'echo 0.1.3 > "$HOME/.cmux/.last_seen_version"; [[ "$(cmux version 2>&1)" == *"cmux 0.1.3"* ]]'

# ── _cmux_show_update_notes: no seen file ──
check "no seen file: output is silent" \
  isolated 0.1.3 '[[ -z "$(_cmux_show_update_notes 2>&1)" ]]'

check "no seen file: seen file is created with current version" \
  isolated 0.1.3 '_cmux_show_update_notes; [[ "$(<"$HOME/.cmux/.last_seen_version")" == "0.1.3" ]]'

# ── _cmux_show_update_notes: seen file matches ──
check "seen file matches current: output is silent" \
  isolated 0.1.3 'echo 0.1.3 > "$HOME/.cmux/.last_seen_version"; [[ -z "$(_cmux_show_update_notes 2>&1)" ]]'

# ── _cmux_show_update_notes: seen file differs ──
check "seen file older: prints notes" \
  isolated 0.1.3 'echo 0.1.2 > "$HOME/.cmux/.last_seen_version"; [[ "$(_cmux_show_update_notes 2>&1)" == *"what"*"new"* ]]'

check "seen file older: updates seen file to current version" \
  isolated 0.1.3 'echo 0.1.2 > "$HOME/.cmux/.last_seen_version"; _cmux_show_update_notes >/dev/null 2>&1; [[ "$(<"$HOME/.cmux/.last_seen_version")" == "0.1.3" ]]'

check "seen file older, no notes for current version: silent but still updates seen file" \
  isolated 999.0.0 'echo 0.1.2 > "$HOME/.cmux/.last_seen_version"; out="$(_cmux_show_update_notes 2>&1)"; [[ -z "$out" && "$(<"$HOME/.cmux/.last_seen_version")" == "999.0.0" ]]'

check "seen file older, NOTES.md missing: silent and still updates seen file" \
  isolated_no_notes 0.1.3 'echo 0.1.2 > "$HOME/.cmux/.last_seen_version"; out="$(_cmux_show_update_notes 2>&1)"; [[ -z "$out" && "$(<"$HOME/.cmux/.last_seen_version")" == "0.1.3" ]]'

# ── Summary ──
echo ""
total=$((passes + fails))
if [[ $fails -eq 0 ]]; then
  echo "All $total tests passed."
  exit 0
else
  echo "$passes/$total passed, $fails failed."
  exit 1
fi
