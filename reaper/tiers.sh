#!/bin/sh
#
# merlin's reaper run verb: the tiered test battery.
#
# Structure follows docs/testing-methodology.md -- a portfolio of oracles, not
# a pyramid. Each tier answers a question no cheaper tier can, and a tier that
# is not yet built is *reported as not built* rather than passing silently. A
# battery whose unimplemented half reads as green is the same defect as an
# invariant that never fires.
#
# No pipelines whose exit status matters: /bin/sh has no `pipefail`.

set -eu

. "$(dirname "$0")/lib.sh"

: "${REAPER_OUT:?not running under reaper}"
: "${REAPER_STATE:?}"
merlin_export_caches

LEDGER="$REAPER_OUT/tiers.tsv"
: > "$LEDGER"
failed=0

note() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$LEDGER"; }

# tier <n> <name> <command...>
# Each tier's own output goes to its log, which means the connection sees
# nothing at all while a tier runs. reaper's io_timeout is measured in SILENCE,
# so a tier that legitimately takes several minutes -- tier 9 shrinking a
# failing trace re-runs whole houses -- is indistinguishable from a wedged
# session, and the run is killed with its results thrown away.
#
# So: a heartbeat. It says nothing useful except "still alive", which is
# exactly the thing that was missing.
tier() {
    n=$1; shift
    name=$1; shift
    say "tier $n: $name"

    "$@" > "$REAPER_OUT/tier-$n.log" 2>&1 &
    cmd_pid=$!

    # Elapsed counted here, not read from $SECONDS: that is a bash variable and
    # this runs under /bin/sh, where `set -u` made every heartbeat print
    # "SECONDS: parameter not set" instead of a time. The heartbeat still fired,
    # so the run never wedged -- it just stopped saying anything useful, which
    # is the failure mode a heartbeat exists to prevent.
    elapsed=0

    (
        while kill -0 "$cmd_pid" 2>/dev/null; do
            sleep 30
            elapsed=$((elapsed + 30))
            kill -0 "$cmd_pid" 2>/dev/null && \
                printf '    tier %s still running (%ss)\n' "$n" "$elapsed"
        done
    ) &
    hb_pid=$!

    status=0
    wait "$cmd_pid" || status=$?
    kill "$hb_pid" 2>/dev/null || true
    wait "$hb_pid" 2>/dev/null || true

    if [ "$status" -eq 0 ]; then
        note "$n" "pass" "$name"
        say "tier $n: pass"
    else
        note "$n" "FAIL" "$name"
        failed=$((failed + 1))

        # Keep the evidence somewhere the next run will not delete.
        #
        # build.sh clears $REAPER_OUT before every build, so a failing tier's
        # log survived exactly until the next run. Tier 9 shrinks a failing
        # trace over several minutes and then wrote it into a file with a
        # lifetime of one loop -- the expensive work done and the answer thrown
        # away. One intermittent violation was lost that way, and the seed
        # alone did not bring it back.
        #
        # $REAPER_STATE is rolled back between scenarios but not cleared by the
        # build, and the archive is keyed by tier, seed and time so two
        # failures never collide.
        archive="$REAPER_STATE/failures"
        mkdir -p "$archive"
        stamp=$(date -u '+%Y%m%dT%H%M%SZ')
        kept="$archive/tier-$n-$stamp-seed-$SEED.log"
        cp "$REAPER_OUT/tier-$n.log" "$kept" 2>/dev/null || true

        # And a copy in out/, so it comes back with this run's results rather
        # than staying on a guest nobody will log into.
        cp "$REAPER_OUT/tier-$n.log" "$REAPER_OUT/FAILED-tier-$n.log" 2>/dev/null || true

        say "tier $n: FAIL (out/tier-$n.log, kept as out/FAILED-tier-$n.log)"
        say "        archived on the guest: $kept"
    fi
}

# skip <n> <name> <reason> -- recorded, never counted as a pass
skip() {
    note "$1" "not-built" "$2 -- $3"
    printf '    tier %s: NOT BUILT (%s)\n' "$1" "$3"
}

# ---------------------------------------------------------------------------
# Determinism. Every tier that uses randomness takes its seed from here, and
# the seed is written to out/ so any failure replays. Passed in by the caller
# when reproducing; generated and recorded otherwise.
# ---------------------------------------------------------------------------
SEED="${MERLIN_SEED:-$(od -An -N4 -tu4 < /dev/urandom | tr -d ' ')}"
export MERLIN_SEED="$SEED"
printf '%s\n' "$SEED" > "$REAPER_OUT/seed.txt"
say "seed $SEED (export MERLIN_SEED=$SEED to replay)"

# ---------------------------------------------------------------------------
# Tier 0 -- harness self-test. Not one of the eleven. It proves the things
# every later tier assumes, so that a tier-6 failure is never really a broker
# that was not listening.
# ---------------------------------------------------------------------------
tier 0 "harness self-test" sh reaper/selftest.sh

# ---------------------------------------------------------------------------
# Tiers 1-4: pure, local, fast. No broker, no network, async.
# ---------------------------------------------------------------------------
export MIX_ENV=test

tier 1 "pure unit" mix test --only tier1 --warnings-as-errors

# Tier 2 is BUILT as of the TUI. The reason it was skipped -- "no rendered
# markup exists yet" -- stopped being true the moment a view produced a
# Merlin.TUI.Buffer, which is a deterministic character grid and a better
# conformance surface than HTML: no cascade, no layout engine.
tier 2 "component conformance" mix test --only tier2 --warnings-as-errors
tier 3 "source-as-data" mix test --only tier3 --warnings-as-errors
tier 4 "server contract" mix test --only tier4 --warnings-as-errors

# ---------------------------------------------------------------------------
# Tiers 5-9: need the broker and/or the full stack.
# ---------------------------------------------------------------------------
tier 5 "daemon vs fakes" mix test --only tier5 --warnings-as-errors
tier 6 "full stack (smoke)" sh reaper/smoke.sh
tier 7 "seeded fuzzing" mix test --only tier7 --warnings-as-errors
tier 8 "concurrency" mix test --only tier8 --warnings-as-errors
# reaper does not forward arbitrary environment variables into the guest, so
# MERLIN_SIM_SEED set on the workstation would silently do nothing and the
# "replay with" line in a tier 9 failure would be a lie. The seed is pinned
# through a FILE instead, which syncs with the tree like everything else:
#
#     echo 3460 > reaper/sim-seed && reaper test
#
# Absent, the tier picks its own and prints it.
if [ -f reaper/sim-seed ]; then
    MERLIN_SIM_SEED=$(tr -dc '0-9' < reaper/sim-seed)
    export MERLIN_SIM_SEED
    say "tier 9 seed pinned to $MERLIN_SIM_SEED by reaper/sim-seed"
fi

tier 9 "simulated house" mix test --only tier9 --warnings-as-errors

# Not "deferred to M9". M9's dashboard is not what happened -- the operator
# interface is a TUI, and a browser audit has nothing to look at. Leaving the
# old reason would have been a lie by omission the moment tier 2 turned on.
skip 10 "live browser audit" "not applicable -- no web UI; the operator interface is a TUI, covered by tier 2"
skip 11 "human evidence"     "not applicable -- single maintainer, no first-timer to observe"

# ---------------------------------------------------------------------------
# Summary. The ledger is the artifact; the exit status is the gate.
# ---------------------------------------------------------------------------
# Leave nothing holding a dataset or a port into the next run.
broker_down

say "ledger:"
cat "$LEDGER"

built=$(awk '$2 != "not-built"' "$LEDGER" | wc -l | tr -d ' ')
pending=$(awk '$2 == "not-built"' "$LEDGER" | wc -l | tr -d ' ')
say "$built tier(s) built, $failed failed, $pending not yet built"

[ "$failed" -eq 0 ] || exit 1
say "run ok -- and note it proves nothing about the $pending tiers above"
