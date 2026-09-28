#!/usr/bin/env bash
# Exercises memory-git-sync.sh in a temp dir with a fake sync engine: dry-run, a clean run, a
# failing run (proves the exit code survives the tee pipe), conflict-marker detection, the
# notify hook, and the two usage-error paths.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$HERE/../memory-git-sync.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $desc (expected $expected, got $actual)"
  fi
}

repo="$TMP/repo"
mkdir -p "$repo/scripts"
engine="$repo/scripts/sync-engine.sh"

write_engine() {
  cat > "$engine" <<EOF
#!/usr/bin/env bash
$1
EOF
  chmod +x "$engine"
}

export MEMSYNC_REPO="$repo"

# 1. --dry-run: exits 0, never runs the engine (marker file must not appear).
marker="$TMP/ran-marker"
write_engine "touch '$marker'; exit 0"
out="$("$WRAPPER" --dry-run 2>&1)"
rc=$?
check "--dry-run exits 0" 0 "$rc"
check "--dry-run does not execute the engine" "0" "$([ -f "$marker" ] && echo 1 || echo 0)"
echo "$out" | grep -q "sync-engine.sh"
check "--dry-run mentions the engine path" 0 $?

# 2. Clean run: engine exits 0 -> wrapper exits 0.
write_engine "echo 'all good'; exit 0"
"$WRAPPER" >/dev/null 2>&1
check "clean engine run exits 0" 0 $?

# 3. Failing run: engine exits 5 -> wrapper must exit 5, NOT tee's exit code.
#    This is the core bug the wrapper fixes (PIPESTATUS vs. \$? after a pipe).
write_engine "echo 'about to fail'; exit 5"
"$WRAPPER" >/dev/null 2>&1
check "failing engine's exit code (5) survives the tee pipe" 5 $?

# 4. Conflict marker: engine prints the marker and exits 0, but the marker means "problem".
#    Verified indirectly via the notify hook below (state=problem despite rc=0).
notify_log="$TMP/notify.log"
notify_cmd="$TMP/notify.sh"
cat > "$notify_cmd" <<EOF
#!/usr/bin/env bash
echo "\$1 \$2 \$3" >> "$notify_log"
EOF
chmod +x "$notify_cmd"

write_engine "echo 'NEEDS-HUMAN: something is stuck'; exit 0"
export MEMSYNC_CONFLICT_MARKER="NEEDS-HUMAN"
export MEMSYNC_NOTIFY_CMD="$notify_cmd"
"$WRAPPER" >/dev/null 2>&1
check "wrapper exits 0 even when the marker is present (engine itself succeeded)" 0 $?
check "notify hook recorded a 'problem' state for the marker" 1 \
  "$(grep -c '^problem resolution-required' "$notify_log" 2>/dev/null || echo 0)"
unset MEMSYNC_CONFLICT_MARKER

# 5. Notify hook on a clean run reports healthy.
: > "$notify_log"
write_engine "echo 'fine'; exit 0"
"$WRAPPER" >/dev/null 2>&1
check "notify hook recorded a 'healthy' state on a clean run" 1 \
  "$(grep -c '^healthy healthy' "$notify_log" 2>/dev/null || echo 0)"
unset MEMSYNC_NOTIFY_CMD

# 6. Missing MEMSYNC_REPO -> exit 2.
env -u MEMSYNC_REPO "$WRAPPER" >/dev/null 2>&1
check "missing MEMSYNC_REPO exits 2" 2 $?

# 7. Engine script missing/not executable -> exit 1.
rm -f "$engine"
"$WRAPPER" >/dev/null 2>&1
check "missing engine script exits 1" 1 $?

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
