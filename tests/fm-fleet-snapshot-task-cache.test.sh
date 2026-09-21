#!/usr/bin/env bash
# Behavioral coverage for the per-task current-state observation cache inside
# bin/fm-fleet-snapshot.sh.
#
# The cache exists so a home whose task inputs are unchanged reuses the prior
# current-state observation instead of re-reading every task endpoint, which
# is what kept a real home's home-summary producer (state/home-summary.json)
# inside its 60-second deadline with margin. The check is behavioral and
# measures the real producer through its wall time:
#
#   cold run   - no cache yet, every task pays a slow current-state read
#   warm run   - inputs unchanged, the producer must reuse the observations
#   invalidation - a status append on one task must force exactly that task
#                to re-read
#   re-warm    - the invalidation cycle's observations are reused again
#
# A 60-second publication deadline with a warm producer well under 5 seconds
# leaves the margin the contract asks for, and each phase asserts against a
# bound that fails before the cache exists (the warm run equals the cold run
# when every task re-reads).
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
BUSY_EVENT="$ROOT/bin/fm-busy-event.sh"
TASK_COUNT=12

# BASH_ENV may prepend the user's mise shims to PATH inside every non-interactive
# bash this test spawns, which would let the real no-mistakes answer instead of
# the fixture stub. The test pins BASH_ENV empty so the fakebin shadow is
# deterministic on any host, matching the environment-pinning pattern the
# bootstrap tests use for their own PATH assertions.
TASK_CACHE_NM_SLEEP=${TASK_CACHE_NM_SLEEP:-4}

TMP_ROOT=$(fm_test_tmproot fm-fleet-snapshot-task-cache)
HOME_DIR="$TMP_ROOT/mate-home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")

cleanup() {
  fm_test_cleanup
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'fixture pane\n> \n' ;;
esac
exit 0
SH
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
# The shared run inventory is the one call the cache itself makes every cycle;
# it must stay instant so the warm run measures observation reuse, not reads.
# An optional marker makes the inventory fail the way a stalled daemon does, so
# the suite can prove the cache survives an unreadable inventory.
echo "$*" >> "$FM_HOME/nm.log"
case "${1:-}" in
  runs)
    [ -f "$FM_HOME/nm-runs-fail" ] && exit 1
    exit 0 ;;
esac
sleep "${TASK_CACHE_NM_SLEEP:-4}"
exit 0
SH
chmod +x "$FAKEBIN/tmux" "$FAKEBIN/no-mistakes"

mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config"
printf '# Seeded Firstmate home\n' > "$HOME_DIR/AGENTS.md"
printf 'task-cache\n' > "$HOME_DIR/.fm-secondmate-home"

{
  printf '%s\n' '## In flight'
  i=1
  while [ "$i" -le "$TASK_COUNT" ]; do
    printf '%s\n' "- [ ] cache-task-$i - Cache fixture (repo: firstmate) (kind: ship)"
    i=$((i + 1))
  done
  printf '%s\n' '' '## Queued' '' '## Done'
} > "$HOME_DIR/data/backlog.md"

i=1
while [ "$i" -le "$TASK_COUNT" ]; do
  worktree="$HOME_DIR/projects/cache-task-$i"
  mkdir -p "$worktree"
  fm_git_init_commit "$worktree"
  git -C "$worktree" checkout -q -b "fm/cache-task-$i"
  fm_write_meta "$HOME_DIR/state/cache-task-$i.meta" \
    "window=fmtest:fm-cache-task-$i" \
    "worktree=$worktree" \
    "project=firstmate" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "spawn_gen=fm.cache-task-$i"
  printf 'working: fixture state\n' > "$HOME_DIR/state/cache-task-$i.status"
  busy_gen=$("$BUSY_EVENT" arm "$HOME_DIR/state" "cache-task-$i")
  "$BUSY_EVENT" apply "$HOME_DIR/state" "cache-task-$i" idle \
    --gen "$busy_gen" --source claude-hook --event stop
  i=$((i + 1))
done

run_producer() {
  local start end
  start=$(date +%s)
  : > "$HOME_DIR/nm.log"
  BASH_ENV='' PATH="$FAKEBIN:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_SNAPSHOT_NOW="2026-08-28T10:00:00Z" FM_SNAPSHOT_NOW_EPOCH=1787911200 \
    "$SNAPSHOT" --secondmate-home-summary > "$TMP_ROOT/producer.json" 2>/dev/null \
    || fail "producer failed"
  end=$(date +%s)
  printf '%s' "$((end - start))"
}

# Every taxonomy of a real per-task read is a non-runs no-mistakes call. Cold
# equals TASK_COUNT, warm equals zero, and load can only slow the wall clock
# for both runs together, so the run-count is the deterministic reuse signal.
slow_reads() {
  awk '$1 != "runs" { n++ } END { print n + 0 }' "$HOME_DIR/nm.log"
}

validate_summary() {  # <freshness-mode: fresh|cached|invalidated>
  local mode=$1
  jq -e --arg home "$HOME_DIR" --argjson want "$TASK_COUNT" --arg mode "$mode" '
    .schema == "fm-secondmate-home-summary.v1"
    and .home == $home
    and .valid == true
    and (.endpoints | length) == $want
    and (
      if $mode == "fresh" then ([.endpoints[].endpoint.freshness] | all(. == "fresh"))
      elif $mode == "cached" then ([.endpoints[].endpoint.freshness] | all(. == "cached"))
      else
        ([.endpoints[] | select(.id == "cache-task-1") | .endpoint.freshness] == ["fresh"])
        and ([.endpoints[] | select(.id != "cache-task-1") | .endpoint.freshness]
             | all(. == "cached"))
      end
    )
  ' "$TMP_ROOT/producer.json" >/dev/null \
    || fail "published summary did not keep its schema, task inventory, or $mode observation provenance"
}

# Cold: no cache exists, so every task pays the slow current-state read. Twelve
# tasks at eight-way concurrency are two waves of the four-second stub, so the
# producer cannot complete under six seconds even on an idle host.
cold_elapsed=$(run_producer)
validate_summary fresh
[ "$cold_elapsed" -ge 6 ] \
  || fail "cold producer finished in ${cold_elapsed}s; the slow read stub did not bind"
[ "$(slow_reads)" -eq "$TASK_COUNT" ] \
  || fail "cold producer ran $(slow_reads) current-state reads, expected $TASK_COUNT"
pass "cold producer pays one current-state read per task"

# Warm: no task input changed, so every observation must be reused. The warm
# run must issue no slow read at all and finish well under half the cold wall
# time - a full re-read equals the cold run, and a partial one still costs slow
# reads. The relative bound keeps the gate honest on a loaded host, where the
# absolute clock inflates for both runs together.
warm_elapsed=$(run_producer)
validate_summary cached
[ "$(slow_reads)" -eq 0 ] \
  || fail "warm producer issued $(slow_reads) slow reads; unchanged tasks were re-read instead of reused"
[ "$warm_elapsed" -lt $((cold_elapsed / 2)) ] \
  || fail "warm producer took ${warm_elapsed}s vs a ${cold_elapsed}s cold run; unchanged tasks were re-read instead of reused"
[ "$warm_elapsed" -lt 30 ] \
  || fail "warm producer took ${warm_elapsed}s; the 60-second deadline needs wider margin"
pass "unchanged tasks reuse their prior observation with margin under the deadline"

# Invalidation: a status append is one task changing, and only that task may
# pay the slow read again. The single four-second read dominates the wall time.
printf 'paused: the fixture changed\n' >> "$HOME_DIR/state/cache-task-1.status"
invalidated_elapsed=$(run_producer)
validate_summary invalidated
[ "$(slow_reads)" -eq 1 ] \
  || fail "changed task issued $(slow_reads) slow reads, expected exactly 1"
[ "$invalidated_elapsed" -ge 3 ] \
  || fail "changed task took ${invalidated_elapsed}s; the observation cache ignored the status append"
pass "a task change invalidates exactly the changed task"

# Re-warm: the invalidation cycle stored fresh observations for every task, so
# the producer is back to reuse and the margin under the deadline returns.
rewarm_elapsed=$(run_producer)
validate_summary cached
[ "$(slow_reads)" -eq 0 ] \
  || fail "re-warm producer issued $(slow_reads) slow reads; observations were not stored for reuse"
[ "$rewarm_elapsed" -lt $((cold_elapsed / 2)) ] \
  || fail "re-warm producer took ${rewarm_elapsed}s vs a ${cold_elapsed}s cold run; observations were not stored for reuse"
pass "fresh observations from a changed run are stored for the next cycle"

# Stalled inventory: the daemon stops answering the shared run inventory mid-
# cadence. The cache must keep reusing the last-good fingerprint instead of
# falling back to a full live re-read, so the summary cannot blow its deadline
# in the same cycle its daemon is sick.
printf 'x\n' > "$HOME_DIR/nm-runs-fail"
stalled_elapsed=$(run_producer)
validate_summary cached
rm -f "$HOME_DIR/nm-runs-fail"
[ "$(slow_reads)" -eq 0 ] \
  || fail "stalled-inventory producer issued $(slow_reads) slow reads; an unreadable run inventory evicted the whole cache"
[ "$stalled_elapsed" -lt $((cold_elapsed / 2)) ] \
  || fail "stalled-inventory producer took ${stalled_elapsed}s vs a ${cold_elapsed}s cold run; the evicted cache missed the deadline margin"
pass "an unreadable run inventory keeps the cached observations instead of re-reading every task"