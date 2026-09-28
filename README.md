# memory-git-sync

A shell wrapper for running a git-based sync engine on a schedule (cron, systemd timer, CI):
it logs the engine's output while still preserving its real exit code, and can optionally raise
a "problem" vs. "healthy" signal to an external notifier, including for failure modes that don't
show up as a non-zero exit code at all.

It exists because of one specific, easy-to-write bug: `engine.sh 2>&1 | tee "$log"` followed by
checking `$?` checks the exit code of `tee`, not `engine.sh`. `tee` almost always succeeds, so
a caller written this way treats every run as a success no matter what the engine did.
This is what happened to the script this was extracted from: a scheduled sync job kept
reporting healthy for a week while a real git merge conflict sat unresolved, because the wrapper
piped to `tee` without ever reading `${PIPESTATUS[0]}`. The fix is one line once you know to
look for it, but it's the kind of bug that silently degrades a monitoring signal to "always
green" instead of causing a loud failure. That is worth a small, reusable, tested wrapper
instead of re-deriving it per project.

This wrapper does not itself implement git sync. You bring your own idempotent sync engine
script (fetch, merge, resolve, push, whatever your case needs) and point this at it. What this
gives you is the surrounding shell: run it, tee it, get the real exit code back, and optionally
notify on a marker string in the output or on a non-zero exit.

## Install

```sh
cp memory-git-sync.sh /usr/local/bin/memory-git-sync.sh
chmod +x /usr/local/bin/memory-git-sync.sh
```

Requires `bash` (uses `PIPESTATUS`) and standard coreutils.

## Usage

```
memory-git-sync.sh [--dry-run]
```

Configure it entirely through environment variables (see `--help` for the full list):

| variable | required | default | purpose |
|---|---|---|---|
| `MEMSYNC_REPO` | yes | none | path to the git repo containing your sync engine |
| `MEMSYNC_ENGINE` | no | `scripts/sync-engine.sh` | engine script path, relative to `MEMSYNC_REPO` |
| `MEMSYNC_ACTOR` | no | `$(whoami)@$(hostname -s)` | passed to the engine as `SYNC_ACTOR` |
| `MEMSYNC_LOCK_FILE` | no | `$MEMSYNC_REPO/.git/memory-git-sync.lock` | passed as `SYNC_LOCK_FILE` |
| `MEMSYNC_CONFLICT_LOG` | no | `$MEMSYNC_REPO/.git/memory-git-sync-conflicts.log` | passed as `SYNC_CONFLICT_LOG` |
| `MEMSYNC_CONFLICT_MARKER` | no | unset (disabled) | a string; if it appears in the engine's output, the run is reported as `problem` even if the engine exited 0 |
| `MEMSYNC_NOTIFY_CMD` | no | unset (disabled) | run after every attempt as `$MEMSYNC_NOTIFY_CMD <state> <key> "<headline>"` |

Your engine script receives `SYNC_REPO`, `SYNC_ACTOR`, `SYNC_LOCK_FILE`, and `SYNC_CONFLICT_LOG`
as environment variables; use them however your sync logic needs (an actor tag on commits, a
lock file to avoid overlapping runs, a place to log unresolved conflicts for a human or agent to
pick up).

```sh
export MEMSYNC_REPO=/path/to/your/repo
export MEMSYNC_CONFLICT_MARKER="RESOLUTION REQUIRED"
export MEMSYNC_NOTIFY_CMD=/usr/local/bin/notify-healthcheck
memory-git-sync.sh
```

`--dry-run` prints the resolved configuration (engine path, exported variables, whether the
engine is present and executable) and exits 0 without running anything. Use it to sanity-check
a new cron/systemd unit before it runs for real.

## Exit codes

| code | meaning |
|------|---------|
| 0    | the engine ran and exited 0 |
| 1    | the engine's script was missing/not executable, or the engine exited 1 |
| 2    | usage error (`MEMSYNC_REPO` unset, or an unknown flag) |
| *n*  | any other value the engine itself exits with, passed straight through |

Note that a `MEMSYNC_CONFLICT_MARKER` hit is reported to `MEMSYNC_NOTIFY_CMD` as a `problem`
state regardless of the engine's exit code. The wrapper's own exit code still just reflects
whether the engine process itself exited zero.

## Tests

```sh
bash tests/test_memory_git_sync.sh
```

Runs the wrapper against a small fake engine script in a temp directory and checks: `--dry-run`
never executes the engine, a clean run exits 0, a failing run's exit code (5, arbitrarily chosen)
survives the `tee` pipe intact, the conflict-marker and notify-hook paths fire with the right
state, and the two usage-error paths (missing `MEMSYNC_REPO`, missing engine script) exit 2 and 1
respectively.

## Where this came from

This is a generalized version of a machine-local wrapper that originally just `exec`'d a fixed
sync binary at an absolute, machine-specific path. That version had no logging, no exit-code
handling, and no configurability, so there was nothing worth extracting from it. The version
here is rebuilt from a second, more capable copy of the wrapper that implemented the
tee/PIPESTATUS/notify logic, with all environment- and host-specific values (repo paths, actor
naming, a project-specific notifier script) replaced by the environment variables documented
above.

Built for an eleven-seat setup where Claude Code, Codex, and Grok edit the same repositories at
once. Written with coding agents, designed and reviewed by Sean Egan. See
https://sean.theinformed.org/method/
