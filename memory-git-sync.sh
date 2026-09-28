#!/usr/bin/env bash
# memory-git-sync: a thin wrapper around a git-based sync engine that fixes a specific class of
# silent failure — an exit code lost behind a pipe — and adds optional health notification.
#
# THE PROBLEM THIS FIXES
#   A very common pattern for "run a script and also log its output" is:
#       my-sync-engine.sh 2>&1 | tee "$log"
#   Under `set -e`, or in any caller that checks `$?` afterward, this is a trap: `$?` after a
#   pipeline is the exit status of the LAST command in the pipe — `tee` — which almost always
#   succeeds, regardless of whether `my-sync-engine.sh` failed. A caller that `exec`s the engine
#   directly avoids this, but then loses the ability to tee output anywhere; a caller that pipes
#   to `tee` without reading `PIPESTATUS` silently treats every run as a success. Either way,
#   nothing downstream ever learns the engine failed.
#
#   This script exists because that exact bug caused a real outage: a scheduled sync job kept
#   "succeeding" for a week while a repository merge conflict sat unresolved, because the wrapper
#   piped to `tee` and never checked `PIPESTATUS`.
#
# WHAT THIS SCRIPT DOES
#   1. Locates a sync engine script inside a git repo you point it at.
#   2. Exports a few standard environment variables the engine can use for its actor identity,
#      lock file, and conflict log.
#   3. Runs the engine, tees its combined stdout/stderr to a temp log AND to your terminal, and
#      captures its real exit code via `PIPESTATUS` — the bug above, fixed.
#   4. Optionally scans the log for a "needs a human/agent to resolve a merge" marker string,
#      and/or runs an external notification command with the resulting state — so a monitoring
#      system can page on `problem`, not just on "the cron job errored."
#   5. Exits with the engine's own exit code (not `tee`'s), so a caller checking `$?` sees the
#      truth.
#
# This script does not implement git sync itself — it assumes you already have (or will write)
# an idempotent sync engine script that lives inside the repo it manages (so the engine's own
# logic is versioned alongside the content it syncs). This wrapper is the part worth reusing:
# the "run it, log it, don't lose the exit code, notify on real state" shell around it.
set -uo pipefail

usage() {
  cat <<'USAGE' >&2
usage: memory-git-sync.sh [--dry-run]

Environment variables (all optional except MEMSYNC_REPO):
  MEMSYNC_REPO              path to the git repo containing the sync engine (required)
  MEMSYNC_ENGINE            path to the engine script, relative to MEMSYNC_REPO
                            (default: scripts/sync-engine.sh)
  MEMSYNC_ACTOR             identity string passed to the engine as SYNC_ACTOR
                            (default: "$(whoami)@$(hostname -s)")
  MEMSYNC_LOCK_FILE         lock file path passed to the engine as SYNC_LOCK_FILE
                            (default: MEMSYNC_REPO/.git/memory-git-sync.lock)
  MEMSYNC_CONFLICT_LOG      conflict log path passed to the engine as SYNC_CONFLICT_LOG
                            (default: MEMSYNC_REPO/.git/memory-git-sync-conflicts.log)
  MEMSYNC_CONFLICT_MARKER   a string that, if it appears in the engine's output, means a human
                            or agent must resolve something by hand (default: unset — disabled)
  MEMSYNC_NOTIFY_CMD        a command to run after every attempt, invoked as:
                              $MEMSYNC_NOTIFY_CMD <state> <key> "<headline>"
                            where <state> is "healthy" or "problem" (default: unset — disabled)

--dry-run prints what would be exported and which engine would be run, then exits 0 without
running it. Useful for verifying configuration in CI or before wiring up a real cron/systemd
timer.
USAGE
}

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "memory-git-sync.sh: unknown argument: $arg" >&2; usage; exit 2 ;;
  esac
done

if [ -z "${MEMSYNC_REPO:-}" ]; then
  echo "memory-git-sync.sh: MEMSYNC_REPO is not set — nothing to sync." >&2
  usage
  exit 2
fi

repo="$MEMSYNC_REPO"
engine="$repo/${MEMSYNC_ENGINE:-scripts/sync-engine.sh}"

export SYNC_REPO="$repo"
export SYNC_ACTOR="${MEMSYNC_ACTOR:-$(whoami)@$(hostname -s 2>/dev/null || hostname)}"
export SYNC_LOCK_FILE="${MEMSYNC_LOCK_FILE:-$repo/.git/memory-git-sync.lock}"
export SYNC_CONFLICT_LOG="${MEMSYNC_CONFLICT_LOG:-$repo/.git/memory-git-sync-conflicts.log}"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "memory-git-sync.sh --dry-run"
  echo "  engine             : $engine"
  echo "  SYNC_REPO          : $SYNC_REPO"
  echo "  SYNC_ACTOR         : $SYNC_ACTOR"
  echo "  SYNC_LOCK_FILE     : $SYNC_LOCK_FILE"
  echo "  SYNC_CONFLICT_LOG  : $SYNC_CONFLICT_LOG"
  echo "  conflict marker    : ${MEMSYNC_CONFLICT_MARKER:-<disabled>}"
  echo "  notify command     : ${MEMSYNC_NOTIFY_CMD:-<disabled>}"
  if [ -x "$engine" ]; then
    echo "  engine executable  : yes"
  else
    echo "  engine executable  : NO — $engine not found or not executable"
  fi
  exit 0
fi

if [ ! -x "$engine" ]; then
  printf '%s ERROR: sync engine missing or not executable at %s\n' \
    "$(date -u +%FT%TZ)" "$engine" >&2
  exit 1
fi

run_log="$(mktemp "${TMPDIR:-/tmp}/memory-git-sync.XXXXXX")"
trap 'rm -f "$run_log"' EXIT

set +e
"$engine" 2>&1 | tee "$run_log"
# THE FIX: PIPESTATUS[0] is the engine's own exit code, not tee's. Without this, a caller
# checking `$?` after the pipeline always sees tee's (near-always-zero) status instead.
rc=${PIPESTATUS[0]}
set -e

if [ -n "${MEMSYNC_CONFLICT_MARKER:-}" ] && grep -qF "$MEMSYNC_CONFLICT_MARKER" "$run_log" 2>/dev/null; then
  state=problem
  key=resolution-required
  headline="Sync hit a condition that needs manual resolution (marker: $MEMSYNC_CONFLICT_MARKER). See $SYNC_CONFLICT_LOG and the run log."
elif [ "$rc" -ne 0 ]; then
  state=problem
  key="rc-$rc"
  headline="Sync engine exited $rc."
else
  state=healthy
  key=healthy
  headline="Sync completed with no conflicts."
fi

if [ -n "${MEMSYNC_NOTIFY_CMD:-}" ]; then
  # Best-effort: a broken notifier must never mask the engine's real exit code.
  $MEMSYNC_NOTIFY_CMD "$state" "$key" "$headline" >/dev/null 2>&1 || true
fi

exit "$rc"
