#!/bin/sh
#
# Tier 6 (partial): full stack, real broker, no mocks.
#
# Starts the actual release -- not `mix run`, not a test harness -- against a
# real mosquitto, and asserts a ping/pong round-trip. That single exchange
# proves the connection, the declared subscription, the router, the adapter,
# the emission path and the publish path, end to end.
#
# This is not the whole of tier 6. The hostile-start half (a database
# pre-seeded with the legacy Python schema, a stale fact snapshot) needs
# persistence, which does not exist yet. The ledger says so rather than
# letting this stand in for it.

set -eu

. "$(dirname "$0")/lib.sh"
merlin_export_caches

REL="$MIX_BUILD_ROOT/prod/rel/merlin"
[ -x "$REL/bin/merlin" ] || die "no release at $REL -- did build.sh run?"

MERLIN_STATE_DIR="$REAPER_STATE/merlin"
export MERLIN_STATE_DIR
mkdir -p "$MERLIN_STATE_DIR/tmp"

export MERLIN_BROKER_HOST=127.0.0.1
export MERLIN_BROKER_PORT=1883
export MERLIN_CLIENT_ID="merlin-smoke-$$"
# Loopback only; the guest has no business advertising a distribution port.
export RELEASE_NODE="merlin-smoke@127.0.0.1"

broker_up

cleanup() {
    "$REL/bin/merlin" stop >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

say "starting the release"
"$REL/bin/merlin" daemon || die "release failed to start"

# Poll for a working round-trip rather than sleeping a guessed interval. The
# daemon needs a moment to reach the broker, and a fixed sleep would either be
# slow or flaky depending on the guest's mood.
say "waiting for ping/pong"
i=0
got=""
while [ "$i" -lt 30 ]; do
    out="$REAPER_OUT/smoke-pong.txt"
    : > "$out"

    /usr/local/bin/mosquitto_sub -h 127.0.0.1 -t 'test/pong' -C 1 -W 2 > "$out" 2>/dev/null &
    subpid=$!
    sleep 0.2
    /usr/local/bin/mosquitto_pub -h 127.0.0.1 -t 'test/ping' -m 'hello' 2>/dev/null || true
    wait "$subpid" 2>/dev/null || true

    got=$(cat "$out" 2>/dev/null || true)
    [ "$got" = "pong" ] && break

    i=$((i + 1))
done

if [ "$got" != "pong" ]; then
    say "no pong after ${i} attempts; daemon log follows"
    tail -40 "$MERLIN_STATE_DIR/tmp"/*.log 2>/dev/null || true
    "$REL/bin/merlin" rpc 'IO.inspect(Merlin.MQTT.Connection.connected?(), label: "connected?")' 2>&1 || true
    die "ping did not produce a pong"
fi
say "ping -> pong ok"

# The other half of echo parity: state/update becomes a fact. Asserted through
# the running daemon's own view of the world, not through a test double.
#
# `rpc`, not `eval`. `eval` boots a SEPARATE beam with the release's code
# loaded but its applications not started, so it sees an empty world and
# reports the fact as absent -- a passing daemon looking like a broken one.
say "checking state/update -> system.last_message"
marker="smoke-$$-$(od -An -N2 -tu2 < /dev/urandom | tr -d ' ')"
/usr/local/bin/mosquitto_pub -h 127.0.0.1 -t 'state/update' -m "$marker" 2>/dev/null

# stderr goes to a file rather than /dev/null. Discarding it is what turned
# "rpc is the wrong verb" into a silent empty string and cost a whole run.
rpc_err="$REAPER_OUT/smoke-rpc.err"
: > "$rpc_err"

i=0
while [ "$i" -lt 20 ]; do
    seen=$("$REL/bin/merlin" rpc \
        'IO.puts(Merlin.World.get([:system, :last_message]) || "")' 2>>"$rpc_err" | tail -1)
    [ "$seen" = "$marker" ] && break
    i=$((i + 1))
    sleep 0.2
done

if [ "$seen" != "$marker" ]; then
    say "rpc stderr:"
    tail -20 "$rpc_err" || true
    die "state/update did not become system.last_message (saw '$seen', wanted '$marker')"
fi
say "state/update -> fact ok"

# And the claim that matters most about the subscription model: we asked the
# broker for the adapters' declared topics, not for everything.
say "checking we did not subscribe to '#'"
subs=$("$REL/bin/merlin" rpc \
    'Merlin.MQTT.Connection.subscriptions() |> Enum.map(&elem(&1, 0)) |> Enum.join(",") |> IO.puts()' \
    2>>"$rpc_err" | tail -1)
say "subscribed to: $subs"

case ",$subs," in
    *",#,"*) die "subscribed to '#' -- the whole point of declared subscriptions is not to" ;;
esac
[ -n "$subs" ] || die "no subscriptions at all"

say "smoke ok"
