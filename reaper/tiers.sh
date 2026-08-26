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
tier() {
    n=$1; shift
    name=$1; shift
    say "tier $n: $name"
    if "$@" > "$REAPER_OUT/tier-$n.log" 2>&1; then
        note "$n" "pass" "$name"
        say "tier $n: pass"
    else
        note "$n" "FAIL" "$name"
        say "tier $n: FAIL (see out/tier-$n.log)"
        failed=$((failed + 1))
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

skip 2 "component conformance" "deferred to M9; no rendered markup exists yet"
skip 3 "source-as-data"        "lands with the boot validator in M2"
skip 4 "server contract"       "lands with POST /snitch in M3"

# ---------------------------------------------------------------------------
# Tiers 5-9: need the broker and/or the full stack.
# ---------------------------------------------------------------------------
skip 5 "daemon vs fakes"    "Mox over Merlin.MQTT.Client; lands M2/M6"
tier 6 "full stack (smoke)" sh reaper/smoke.sh
skip 7 "seeded fuzzing"     "next after tier 1 -- highest defect-per-line; M3"
skip 8 "concurrency"        "lands with the SQLite WAL claim in M3"
skip 9 "simulated house"    "lands at M7; needs persistence and the settle period"

skip 10 "live browser audit" "deferred to M9"
skip 11 "human evidence"     "not applicable -- single maintainer, no first-timer to observe"

# ---------------------------------------------------------------------------
# Summary. The ledger is the artifact; the exit status is the gate.
# ---------------------------------------------------------------------------
say "ledger:"
cat "$LEDGER"

built=$(awk '$2 != "not-built"' "$LEDGER" | wc -l | tr -d ' ')
pending=$(awk '$2 == "not-built"' "$LEDGER" | wc -l | tr -d ' ')
say "$built tier(s) built, $failed failed, $pending not yet built"

[ "$failed" -eq 0 ] || exit 1
say "run ok -- and note it proves nothing about the $pending tiers above"
