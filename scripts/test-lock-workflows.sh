#!/usr/bin/env bash
# shellcheck shell=bash
# Regression tests for the stale-lockfile retry in mise-lock.yml and
# aube-lock.yml. Each test extracts the workflow step's `run:` script and runs
# it in a scratch git repo against a fake `mise` and `sleep`, so it needs no
# network and no real mise. Requires python3 with PyYAML.
#
# The fake mise emits the same "is locked to a download URL from" message the
# workflows match on. That message is real mise output, so a mise release that
# rewords it is not caught here; the workflows would then stop retrying.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir "$work/bin"
cat > "$work/bin/sleep" <<'EOF'
#!/usr/bin/env bash
echo "sleep $*" >> "$STATE/sleeps"
EOF
# Behaviour is driven by env vars so each test reads as a scenario:
#   LOCK_INEFFECTIVE_CALLS  first N `mise lock` calls exit 0 without refreshing
#   DRYRUN_OTHER_FAILURE    dry-run fails with an unrelated error instead
cat > "$work/bin/mise" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  lock)
    n=$(($(cat "$STATE/lock_calls" 2>/dev/null || echo 0) + 1))
    echo "$n" > "$STATE/lock_calls"
    if [ "$n" -gt "${LOCK_INEFFECTIVE_CALLS:-0}" ]; then touch "$STATE/fresh"; fi
    ;;
  install)
    if [[ " $* " == *" --dry-run "* ]]; then
      if [ -n "${DRYRUN_OTHER_FAILURE:-}" ]; then
        echo "some unrelated install problem"
        exit 1
      fi
      if [ ! -e "$STATE/fresh" ]; then
        echo "aube@2.6.1 is locked to a download URL from 2.6.0 / 2.6.0:"
        exit 1
      fi
    else
      echo "$*" >> "$STATE/installs"
    fi
    ;;
esac
EOF
chmod +x "$work/bin/sleep" "$work/bin/mise"

extract() { # <workflow file> <step name>
  python3 - "$root/.github/workflows/$1" "$2" <<'EOF'
import sys, yaml
workflow = yaml.safe_load(open(sys.argv[1]))
steps = next(iter(workflow["jobs"].values()))["steps"]
print([s for s in steps if s.get("name") == sys.argv[2]][0]["run"])
EOF
}

extract mise-lock.yml "Regenerate mise lockfiles" > "$work/mise-lock.sh"
extract aube-lock.yml "Install mise tools" > "$work/aube-install.sh"
# Only the part of the commit step that runs before anything is staged: the
# rest pushes to GitHub.
extract aube-lock.yml "Commit and push if changed" | sed "/git add -- '\*aube-lock.yaml'/,\$d" > "$work/aube-cleanup.sh"

failures=0
out=""
rc=0

# run <script> <tracked file>: fresh repo and state, then runs the script,
# leaving its combined output in $out and its exit status in $rc.
run() {
  export STATE="$work/state"
  rm -rf "$STATE" "$work/repo"
  mkdir "$STATE" "$work/repo"
  (
    cd "$work/repo"
    git init -q
    if [ -n "${2:-}" ]; then
      echo lock > "$2"
      git add "$2"
    fi
  )
  rc=0
  out="$(cd "$work/repo" && PATH="$work/bin:$PATH" GITHUB_OUTPUT="$work/gh_output" bash -e "$work/$1" 2>&1)" || rc=$?
}

check() { # <description> <condition...>
  local desc="$1"
  shift
  if "$@"; then
    echo "ok   $desc"
  else
    echo "FAIL $desc"
    printf '     | %s\n' "${out//$'\n'/$'\n     | '}"
    failures=$((failures + 1))
  fi
}

count() { if [ -e "$STATE/$1" ]; then wc -l < "$STATE/$1"; else echo 0; fi; }
lock_calls() { cat "$STATE/lock_calls" 2>/dev/null || echo 0; }
rc_is() { [ "$rc" -eq "$1" ]; }
out_has() { grep -q -- "$1" <<< "$out"; }
eq() { [ "$1" = "$2" ]; }

echo "mise-lock.yml"
export LOCK_INEFFECTIVE_CALLS=0 DRYRUN_OTHER_FAILURE=
run mise-lock.sh mise.lock
check "fresh lock passes without retrying" rc_is 0
check "  locks once" eq "$(lock_calls)" 1

export LOCK_INEFFECTIVE_CALLS=1
run mise-lock.sh mise.lock
check "ineffective first lock is retried and then passes" rc_is 0
check "  locks twice" eq "$(lock_calls)" 2
check "  says it is retrying" out_has "retrying"
check "  waits 30s" eq "$(cat "$STATE/sleeps")" "sleep 30"

export LOCK_INEFFECTIVE_CALLS=99
run mise-lock.sh mise.lock
check "permanently stale lock fails after 4 attempts" rc_is 1
check "  locks four times" eq "$(lock_calls)" 4
check "  waits 30s, 60s, 90s" eq "$(tr '\n' ',' < "$STATE/sleeps")" "sleep 30,sleep 60,sleep 90,"
check "  reports the stale entries" out_has "still has stale platform entries after 4 attempts"

export LOCK_INEFFECTIVE_CALLS=0 DRYRUN_OTHER_FAILURE=1
run mise-lock.sh mise.lock
check "unrelated dry-run failure warns and keeps the lockfile" rc_is 0
check "  locks once" eq "$(lock_calls)" 1
check "  emits a warning" out_has "::warning::"

run mise-lock.sh
check "no tracked lockfile is a no-op" rc_is 0
check "  never runs mise" eq "$(lock_calls)" 0

echo "aube-lock.yml"
export LOCK_INEFFECTIVE_CALLS=0 DRYRUN_OTHER_FAILURE=
run aube-install.sh mise.lock
check "fresh lock installs with --locked" rc_is 0
check "  locks once" eq "$(lock_calls)" 1
check "  installs with --locked" eq "$(cat "$STATE/installs")" "install --locked"

export LOCK_INEFFECTIVE_CALLS=1
run aube-install.sh mise.lock
check "ineffective first lock is retried and then installs" rc_is 0
check "  locks twice" eq "$(lock_calls)" 2
check "  installs with --locked" eq "$(cat "$STATE/installs")" "install --locked"

export LOCK_INEFFECTIVE_CALLS=99
run aube-install.sh mise.lock
check "permanently stale lock fails after 4 attempts" rc_is 1
check "  locks four times" eq "$(lock_calls)" 4
check "  never installs" eq "$(count installs)" 0

export LOCK_INEFFECTIVE_CALLS=0 DRYRUN_OTHER_FAILURE=1
run aube-install.sh mise.lock
check "unrelated dry-run failure goes on to the install step" rc_is 0
check "  locks once" eq "$(lock_calls)" 1
check "  installs with --locked" eq "$(cat "$STATE/installs")" "install --locked"

export DRYRUN_OTHER_FAILURE=
run aube-install.sh
check "no tracked mise.lock does a plain install" rc_is 0
check "  never locks" eq "$(lock_calls)" 0
check "  installs without --locked" eq "$(cat "$STATE/installs")" "install"

echo "aube-lock.yml (before commit)"
# What "Install mise tools" leaves behind for a v2 lockfile: a modified
# lockfile, a rewritten and a deleted tracked sidecar, and a new untracked one.
run aube-cleanup.sh mise.lock
(
  cd "$work/repo"
  mkdir -p .mise/locks/prettier/1/node_modules .mise/locks/prettier/2/node_modules
  echo old > .mise/locks/prettier/1/node_modules/.aube-lock.yaml
  echo keep > .mise/locks/prettier/2/node_modules/.aube-lock.yaml
  git add .mise
  git -c user.email=t@t -c user.name=t commit -qm base
  echo refreshed > mise.lock
  echo refreshed > .mise/locks/prettier/2/node_modules/.aube-lock.yaml
  rm .mise/locks/prettier/1/node_modules/.aube-lock.yaml
  mkdir -p .mise/locks/prettier/3/node_modules
  echo new > .mise/locks/prettier/3/node_modules/.aube-lock.yaml
  echo generated > aube-lock.yaml
)
rc=0
out="$(cd "$work/repo" && PATH="$work/bin:$PATH" bash -e "$work/aube-cleanup.sh" 2>&1)" || rc=$?
dirty() { [ -z "$(git -C "$work/repo" status --porcelain --untracked-files=all -- . ':!aube-lock.yaml')" ]; }
check "runner-local lockfile and sidecar changes are discarded" dirty
check "  leaves the regenerated aube-lock.yaml alone" grep -q generated "$work/repo/aube-lock.yaml"
check "  lets git rebase --onto start" git -C "$work/repo" -c user.email=t@t -c user.name=t rebase --onto HEAD HEAD

if [ "$failures" -ne 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
