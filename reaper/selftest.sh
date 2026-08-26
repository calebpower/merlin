#!/bin/sh
#
# Tier 0: harness self-test.
#
# Not one of the eleven tiers. It proves the assumptions every later tier
# rests on, so that a tier-6 failure is never actually a broker that was not
# listening or a cache that was silently writing to the root disk.
#
# The methodology's rule about invariants applies to harnesses too: a check
# that has never been observed failing is a check nobody has verified. Each
# assertion here is one that has a plausible way to go wrong on this guest.

set -eu

. "$(dirname "$0")/lib.sh"

fails=0
check() {
    what=$1; shift
    if "$@"; then
        printf '  ok    %s\n' "$what"
    else
        printf '  FAIL  %s\n' "$what"
        fails=$((fails + 1))
    fi
}

say "reaper environment"
check "REAPER_WORK is set"  test -n "${REAPER_WORK:-}"
check "REAPER_OUT is set"   test -n "${REAPER_OUT:-}"
check "REAPER_STATE is set" test -n "${REAPER_STATE:-}"
check "REAPER_OUT writable"   test -w "${REAPER_OUT:-/nonexistent}"
check "REAPER_STATE writable" test -w "${REAPER_STATE:-/nonexistent}"

merlin_export_caches

say "caches are on the pool, not the root disk"
# The load-bearing constraint from docs/tenants.md: a tenant that lets its
# package manager write under $HOME runs the root filesystem out of space. The
# root disk is ~4 GiB; the pool is tens of GiB. Assert the difference rather
# than trusting that the exports above were spelled correctly.
root_avail_k=$(df -k / | awk 'NR==2 {print $4}')
for c in "$PKG_CACHEDIR" "$HEX_HOME" "$MIX_HOME" "$MIX_DEPS_PATH" "$MIX_BUILD_ROOT"; do
    mkdir -p "$c"
    c_avail_k=$(df -k "$c" | awk 'NR==2 {print $4}')
    # Same filesystem as / would report identical available space.
    if [ "$c_avail_k" = "$root_avail_k" ]; then
        printf '  FAIL  %s is on the root filesystem\n' "$c"
        fails=$((fails + 1))
    else
        printf '  ok    %s is off-root (%s KiB free)\n' "$c" "$c_avail_k"
    fi
done

say "state is rollback-capable"
# $REAPER_STATE must be on ZFS or `reaper reset` has nothing to roll back and
# tiers 6+ silently accumulate state between scenarios -- which would not fail
# anything, it would just quietly stop being a fresh start.
state_fstype=$(df -T "$REAPER_STATE" 2>/dev/null | awk 'NR==2 {print $2}')
if [ "$state_fstype" = "zfs" ]; then
    printf '  ok    REAPER_STATE is on zfs\n'
else
    printf '  FAIL  REAPER_STATE is on %s, not zfs -- reset would be a no-op\n' "${state_fstype:-unknown}"
    fails=$((fails + 1))
fi

say "toolchain"
check "erl present"    command -v erl
check "elixir present" command -v elixir
check "gmake present"  command -v gmake

say "broker round-trip"
if broker_up; then
    printf '  ok    broker listening on 127.0.0.1:1883\n'
    topic="merlin/selftest/$$"
    out="${REAPER_OUT}/selftest-broker.txt"
    : > "$out"

    # Subscriber backgrounded from THIS shell, so $! is a direct child and
    # `wait` can actually reach it. -C 1 exits after one message and -W 5
    # bounds the wait, so a broker that accepts connections but never delivers
    # fails the tier instead of hanging the session until its TTL expires.
    /usr/local/bin/mosquitto_sub -h 127.0.0.1 -t "$topic" -C 1 -W 5 > "$out" 2>/dev/null &
    subpid=$!

    sleep 0.3
    /usr/local/bin/mosquitto_pub -h 127.0.0.1 -t "$topic" -m 'pong' 2>/dev/null || true
    wait "$subpid" 2>/dev/null || true

    if [ "$(cat "$out" 2>/dev/null)" = "pong" ]; then
        printf '  ok    publish/subscribe round-trip\n'
    else
        printf '  FAIL  publish/subscribe round-trip (got %s)\n' "$(cat "$out" 2>/dev/null || echo '<nothing>')"
        fails=$((fails + 1))
    fi
else
    printf '  FAIL  broker did not come up\n'
    fails=$((fails + 1))
fi

say "$fails failure(s)"
[ "$fails" -eq 0 ] || exit 1
