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

# The release defaults MERLIN_CONFIG to /usr/local/etc/merlin/merlin.exs --
# correct for production, where rc.d supplies it, and absent in a disposable
# guest. Point it at the config bundled in the release's own priv, which is
# what a deployment does too: supply the path explicitly rather than relying
# on a fallback.
MERLIN_CONFIG=$(ls "$REL"/lib/merlin-*/priv/merlin.exs 2>/dev/null | head -1)
[ -n "$MERLIN_CONFIG" ] || die "no merlin.exs bundled in the release under $REL/lib/merlin-*/priv/"
export MERLIN_CONFIG
say "config: $MERLIN_CONFIG"

# The shipped config dry-runs by design, which would make every rule log
# instead of act -- and this tier's whole job is to prove effects reach the
# broker. Turn it off for the smoke run only.
export MERLIN_DRY_RUN=false

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
    say "no pong after ${i} attempts -- diagnosing"

    say "--- broker log (authoritative on why it dropped us) ---"
    tail -60 /var/db/mosquitto.log 2>/dev/null || say "(no broker log)"

    say "--- release tmp logs ---"
    find "$MERLIN_STATE_DIR/tmp" -name '*.log*' -exec tail -40 {} \; 2>/dev/null || true

    say "--- is the node even up? ---"
    "$REL/bin/merlin" pid 2>&1 || true

    # Boot the application in a fresh VM in the FOREGROUND. If start-up halts
    # (bad config, missing priv, crashing child) this is where the reason is
    # printed -- rpc cannot tell us, because rpc needs a node that started.
    say "--- foreground boot attempt (5s) ---"
    ( "$REL/bin/merlin" eval 'case Merlin.Config.load() do
          :ok -> IO.puts("config OK: " <> inspect(Map.keys(Merlin.Config.loaded())))
          {:error, errs} -> IO.puts("config FAILED:\n" <> Merlin.Config.File.format_errors(errs))
        end' ) 2>&1 | head -30 || true

    say "--- config path the release would use ---"
    "$REL/bin/merlin" eval 'IO.puts(Merlin.Config.path())' 2>&1 | head -3 || true

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

# ---------------------------------------------------------------------------
# The M2 demonstrable: the button drives the lamps.
#
# This is the whole stack in one exchange -- a declarative source decodes two
# lamp states into facts, a button press becomes an event, a rule's guard
# selects on trigger.value, an expression evaluates all_eq? over a declared
# group, and the group encodes the result onto a zigbee2mqtt topic. None of
# which appears in any Elixir module: it is all config data.
#
# The toggle asymmetry is the interesting half and is transcribed exactly from
# livingroom_lamps.py: target OFF only when BOTH lamps are on, otherwise ON.
# ---------------------------------------------------------------------------
say "checking button -> lamps"

lamp_set='zigbee2mqtt/living_room_lamps/set'
press() {
    /usr/local/bin/mosquitto_pub -h 127.0.0.1 -r \
        -t 'zigbee2mqtt/home/living_room/plug/lamp_1' -m "{\"state\":\"$1\"}" 2>/dev/null
    /usr/local/bin/mosquitto_pub -h 127.0.0.1 -r \
        -t 'zigbee2mqtt/home/living_room/plug/lamp_2' -m "{\"state\":\"$2\"}" 2>/dev/null
    sleep 0.4

    out="$REAPER_OUT/smoke-lamps-$3.txt"
    : > "$out"
    /usr/local/bin/mosquitto_sub -h 127.0.0.1 -t "$lamp_set" -C 1 -W 4 > "$out" 2>/dev/null &
    lamp_sub=$!
    sleep 0.3
    /usr/local/bin/mosquitto_pub -h 127.0.0.1 \
        -t 'zigbee2mqtt/home/living_room/switch/lamps/action' -m "$3" 2>/dev/null
    wait "$lamp_sub" 2>/dev/null || true
    cat "$out" 2>/dev/null
}

# Both on -> a single press turns them off.
got=$(press ON ON single)
case "$got" in
    *OFF*) say "both on + single press -> OFF, correct" ;;
    *) die "both on + single press: expected OFF, got '${got:-<nothing>}'" ;;
esac

# Mixed -> a single press turns them ON. This is the asymmetry; a naive
# toggle would have said OFF here.
got=$(press ON OFF single)
case "$got" in
    *ON*) say "mixed + single press -> ON, correct (the asymmetry holds)" ;;
    *) die "mixed + single press: expected ON, got '${got:-<nothing>}'" ;;
esac

# Double press is a hard off regardless of state -- your decision at planning,
# where the Python had both presses doing the identical thing.
got=$(press ON OFF double)
case "$got" in
    *OFF*) say "mixed + double press -> OFF, correct (hard off)" ;;
    *) die "mixed + double press: expected OFF, got '${got:-<nothing>}'" ;;
esac

# Clear the retained lamp states so the next run starts clean.
for t in lamp_1 lamp_2; do
    /usr/local/bin/mosquitto_pub -h 127.0.0.1 -r -n \
        -t "zigbee2mqtt/home/living_room/plug/$t" 2>/dev/null || true
done

# ---------------------------------------------------------------------------
# dry_run must actually block effects.
#
# The whole cutover plan rests on being able to run against the live broker
# without touching a device. An unverified dry-run that silently failed to
# block would be the worst bug available here: you would believe you were
# shadowing while driving the house. So assert the negative -- and allow time
# to pass, because "nothing happened" is only meaningful with a deadline.
# ---------------------------------------------------------------------------
say "checking dry_run blocks effects"

"$REL/bin/merlin" stop >/dev/null 2>&1 || true
sleep 1

MERLIN_DRY_RUN=true
export MERLIN_DRY_RUN
export MERLIN_CLIENT_ID="merlin-smoke-dry-$$"
"$REL/bin/merlin" daemon || die "release failed to restart in dry-run mode"

# Wait until it is actually connected, or the absence of a pong proves nothing.
i=0
while [ "$i" -lt 40 ]; do
    up=$("$REL/bin/merlin" rpc 'IO.puts(to_string(Merlin.MQTT.Connection.connected?()))' 2>>"$rpc_err" | tail -1)
    [ "$up" = "true" ] && break
    i=$((i + 1))
    sleep 0.25
done
[ "$up" = "true" ] || die "daemon did not connect in dry-run mode; the next assertion would be vacuous"

dry_out="$REAPER_OUT/smoke-dryrun.txt"
: > "$dry_out"
/usr/local/bin/mosquitto_sub -h 127.0.0.1 -t 'test/pong' -C 1 -W 4 > "$dry_out" 2>/dev/null &
dry_sub=$!
sleep 0.3
/usr/local/bin/mosquitto_pub -h 127.0.0.1 -t 'test/ping' -m 'hello' 2>/dev/null || true
wait "$dry_sub" 2>/dev/null || true

if [ -s "$dry_out" ]; then
    die "dry_run did NOT block the publish -- got '$(cat "$dry_out")' on test/pong"
fi
say "dry_run blocked the publish, as it must"

say "smoke ok"
