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

# The shipped config references secrets and does not contain them -- that is
# the whole point of the split, and the daemon rightly refuses to boot without
# them. Write a real 0600 file rather than relaxing the check, because the
# permission refusal is itself something this tier must not disable.
#
# Every endpoint points at a closed loopback port. No DNS, no outbound traffic
# from a disposable guest, and connection-refused arrives in milliseconds --
# which makes the pollers a deliberate test of the failure path rather than an
# accident: a house whose vendor API is unreachable must still work.
MERLIN_SECRETS="$MERLIN_STATE_DIR/merlin.secrets.exs"
export MERLIN_SECRETS
cat > "$MERLIN_SECRETS" <<'SECRETS'
%{
  hapn_auth_endpoint: "http://127.0.0.1:1/token",
  hapn_device_endpoint: "http://127.0.0.1:1/device",
  hapn_client_id: "smoke",
  hapn_client_secret: "smoke",
  weather_endpoint: "http://127.0.0.1:1/weather",
  weather_api_key: "smoke",
  discord_webhook: "http://127.0.0.1:1/webhook"
}
SECRETS
chmod 600 "$MERLIN_SECRETS"
say "secrets: $MERLIN_SECRETS (0600, all endpoints closed loopback)"

# The shipped config dry-runs by design, which would make every rule log
# instead of act -- and this tier's whole job is to prove effects reach the
# broker. Turn it off for the smoke run only.
export MERLIN_DRY_RUN=false

# Distinct ports so a leftover daemon from an earlier run cannot be the thing
# answering -- a check that talks to the wrong process is worse than no check.
MERLIN_PUBLIC_PORT=18080
MERLIN_LOCAL_PORT=18081
export MERLIN_PUBLIC_PORT MERLIN_LOCAL_PORT

export MERLIN_BROKER_HOST=127.0.0.1
export MERLIN_BROKER_PORT=1883
export MERLIN_CLIENT_ID="merlin-smoke-$$"
# Loopback only; the guest has no business advertising a distribution port.
export RELEASE_NODE="merlin-smoke@127.0.0.1"

broker_up

cleanup() {
    # The daemon's own log is the only account of what it thought it was
    # doing, and $REAPER_STATE is rolled back between tiers -- so a failure
    # that does not preserve it is a failure nobody can diagnose. Always, not
    # only on error: a passing run's log is what the next failure is compared
    # against.
    find "$MERLIN_STATE_DIR/tmp" -name '*.log*' -exec cat {} + \
        > "$REAPER_OUT/smoke-daemon.log" 2>/dev/null || true
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
# The M3 demonstrable: key management, and a real key injecting a real fact.
#
# The requirement is specific and is why SQLite was chosen over CubDB: the CLI
# must work with the daemon STOPPED and with it RUNNING, and a key minted while
# it runs must be accepted without a restart.
# ---------------------------------------------------------------------------
say "checking key management against the running daemon"

KEYBIN="$REL/bin/merlin-key"
[ -x "$KEYBIN" ] || die "merlin-key overlay missing from the release"

# Mint while the daemon is up. WAL is what makes this legal at all.
mint_out="$REAPER_OUT/smoke-key-add.txt"
"$KEYBIN" add --topic 'http/mobile/ariia/state' --label smoke > "$mint_out" 2>&1 \
    || { cat "$mint_out"; die "merlin-key add failed while the daemon was running"; }

API_KEY=$(awk '/^  key:/ {print $2}' "$mint_out")
[ -n "$API_KEY" ] || { cat "$mint_out"; die "no key in merlin-key add output"; }
say "minted a key while the daemon was running"

"$KEYBIN" list > "$REAPER_OUT/smoke-key-list.txt" 2>&1 || die "merlin-key list failed"
grep -q 'http/mobile/ariia/state' "$REAPER_OUT/smoke-key-list.txt" \
    || die "the minted key is not in merlin-key list"

# The plaintext must not be recoverable from the listing.
if grep -q "$API_KEY" "$REAPER_OUT/smoke-key-list.txt"; then
    die "merlin-key list printed the key itself -- it is supposed to be stored hashed"
fi
say "list shows the key without revealing it"

# No restart, no reload: the running daemon must accept it on the next request.
say "posting to /snitch with the key just minted"
snitch_out="$REAPER_OUT/smoke-snitch.txt"

# The client is `bin/merlin eval` using OTP's own :httpc. Not fetch(1), which
# is a download tool and silently discards a request body; not curl or python,
# neither of which is reliably on this template -- the guest description lists
# python312 but it is not at /usr/local/bin/python3 here, and guessing at the
# guest's contents is what produced the last two failures.
#
# `eval` boots a SEPARATE beam, so this is a real external client over real
# TCP through Bandit, not the daemon calling itself in-process.
#
# Key and port travel in the environment rather than being interpolated into
# the expression: same reasoning as the merlin-key overlay.
MERLIN_SMOKE_KEY="$API_KEY" MERLIN_SMOKE_PORT="$MERLIN_PUBLIC_PORT" \
"$REL/bin/merlin" eval '
  :inets.start()
  key = System.get_env("MERLIN_SMOKE_KEY")
  port = System.get_env("MERLIN_SMOKE_PORT")

  body =
    Jason.encode!(%{
      challenge: key,
      status: %{gps_latitude: 35.9606, gps_longitude: -83.9207, gps_accuracy: 12}
    })

  url = ~c"http://127.0.0.1:#{port}/snitch"

  case :httpc.request(:post, {url, [], ~c"application/json", body}, [], []) do
    {:ok, {{_, status, _}, _, resp}} -> IO.puts("status=#{status} body=#{resp}")
    other -> IO.puts("request failed: #{inspect(other)}")
  end
' > "$snitch_out" 2>&1 || true

say "snitch response: $(cat "$snitch_out")"

i=0
while [ "$i" -lt 20 ]; do
    lat=$("$REL/bin/merlin" rpc \
        'IO.puts(inspect(Merlin.World.get([:person, :caleb, :lat])))' 2>>"$rpc_err" | tail -1)
    [ "$lat" != "nil" ] && break
    i=$((i + 1))
    sleep 0.2
done

case "$lat" in
    *35.9606*) say "/snitch with a live-minted key produced person.caleb.lat = $lat" ;;
    *) tail -20 "$rpc_err" 2>/dev/null; die "the key did not inject a fact (lat=$lat)" ;;
esac

# The leak that actually happened: api.py logged the request body, and the key
# travels in it.
# ---------------------------------------------------------------------------
# The M4 demonstrable: the geofence, in the running daemon.
#
# Bug 2 executing for the first time. user_location.py:124 produced "" where
# False was meant and every consumer tested `is False`, so being outside every
# zone was indistinguishable from being home and the away path never ran.
# ---------------------------------------------------------------------------
post_position() {
    MERLIN_SMOKE_KEY="$API_KEY" MERLIN_SMOKE_PORT="$MERLIN_PUBLIC_PORT" \
    MERLIN_SMOKE_LAT="$1" MERLIN_SMOKE_LON="$2" \
    "$REL/bin/merlin" eval '
      :inets.start()
      body = Jason.encode!(%{
        challenge: System.get_env("MERLIN_SMOKE_KEY"),
        status: %{
          gps_latitude: String.to_float(System.get_env("MERLIN_SMOKE_LAT")),
          gps_longitude: String.to_float(System.get_env("MERLIN_SMOKE_LON")),
          gps_accuracy: 8
        }
      })
      url = ~c"http://127.0.0.1:#{System.get_env("MERLIN_SMOKE_PORT")}/snitch"
      :httpc.request(:post, {url, [], ~c"application/json", body}, [], [])
    ' >/dev/null 2>&1 || true
}

zone_now() {
    "$REL/bin/merlin" rpc \
        'IO.puts(inspect(Merlin.World.get([:person, :caleb, :zone])))' 2>>"$rpc_err" | tail -1
}

await_zone() {
    want=$1
    i=0
    while [ "$i" -lt 25 ]; do
        got=$(zone_now)
        [ "$got" = "$want" ] && return 0
        i=$((i + 1))
        sleep 0.2
    done
    return 1
}

say "posting a position at the centre of the home zone"
post_position 35.9606 -83.9207
await_zone ":home" || die "expected zone :home, got $(zone_now)"
say "zone resolved to :home"

say "posting a position far outside every zone"
post_position 40.7128 -74.0060
await_zone ":unknown" || die "expected zone :unknown, got $(zone_now)"
say "zone resolved to :unknown -- NOT :home, and not false (bug 2 is fixed)"

say "posting a position just outside the entry radius but inside the exit radius"
# ~130m north of home: beyond the 400ft entry radius, within the 1.25x exit
# radius. Coming from :unknown, hysteresis must keep us OUT.
post_position 35.9617 -83.9207
await_zone ":unknown" || die "hysteresis let us enter on the exit radius (got $(zone_now))"
say "hysteresis held: did not enter on the wider radius"

# --------------------------------------------------------------------------
# A poller whose endpoint is unreachable must degrade, not escalate. In the
# Python a failing runner raised inside the thread and the traceback was
# swallowed, so the only symptom was facts that silently stopped updating.
#
# Both pollers have been failing against a closed port for the whole run. By
# now they must have logged it, must NOT have taken their supervisor with
# them, and the rest of the house -- everything asserted above -- must have
# gone on working. That last part is proven by this script having got here.
# --------------------------------------------------------------------------
say "checking a dead poller endpoint degrades rather than escalating"

poll_log=$(find "$MERLIN_STATE_DIR/tmp" -name '*.log*' -exec cat {} + 2>/dev/null)

# EVERY poller, by name. The first version of this check looked for one
# "poll failed" line anywhere and passed -- while the weather poller was in a
# crash loop that shut the daemon down ninety seconds later. One healthy
# integration masked a fatal one.
for poller in hapn weather; do
    printf '%s\n' "$poll_log" | grep -q "$poller: poll failed" \
        || die "$poller never reported a failure -- it either did not poll, or it died instead"
done
say "both pollers reported their failure by name"

# No poller may terminate. Not "no supervisor report" -- the actual crash was
# logged as `GenServer ... terminating`, which the earlier pattern missed.
if printf '%s\n' "$poll_log" | grep -qE "HttpPoll, :(hapn|weather)\}\} terminating|reached_max_restart"; then
    die "a poller process terminated -- a failing vendor API must not restart, let alone escalate"
fi

# And the daemon itself must still be answering. A crash loop that has already
# taken the application down leaves a log full of plausible warnings; only
# asking the daemon distinguishes degraded from dead.
# `rpc` runs INSIDE the live node, so it fails outright if the application is
# gone -- which `eval` would not, since eval boots its own beam and would
# happily report a healthy-looking empty world over a corpse.
alive=$("$REL/bin/merlin" rpc \
    'IO.puts(if Process.whereis(Merlin.Supervisor), do: "alive", else: "no-supervisor")' \
    2>>"$REAPER_OUT/smoke-rpc.err" | tail -1)

[ "$alive" = "alive" ] || {
    say "rpc stderr:"; tail -20 "$REAPER_OUT/smoke-rpc.err" || true
    die "the daemon stopped answering after the pollers failed (saw '$alive')"
}
say "daemon still alive and answering"

# A token cannot have been issued by a closed port.
if printf '%s\n' "$poll_log" | grep -q "token refreshed"; then
    die "a token was refreshed against a closed port -- impossible; the stub is not what it claims"
fi
say "pollers degraded quietly and the house kept working"

say "checking the key is absent from the daemon log"
if find "$MERLIN_STATE_DIR/tmp" -name '*.log*' -exec grep -l "$API_KEY" {} \; 2>/dev/null | grep -q .; then
    die "the API key appears in the daemon log -- api.py:31 all over again"
fi
say "key absent from the log"

"$KEYBIN" rm --key "$API_KEY" >/dev/null 2>&1 || die "merlin-key rm failed"
say "revoked it"

# ---------------------------------------------------------------------------
# The M5 demonstrable: the printer power cycle, and bug 7.
#
# office_aircond.py restored the A/C on the printer REQUEST value, so a REBOOT
# un-masked immediately and the A/C came back on at t=0 -- during the ten
# seconds the printer was deliberately powered down. Here the load shed
# watches printer.kobra_neo.busy?, which stays true through the dwell, so the
# A/C cannot return until the cycle has actually finished.
#
# This takes ~13s because the dwell is genuinely ten seconds in production
# config. Tier 1 exercises the same state timeout in 25ms by declaring
# milliseconds; this one proves the shipped durations.
# ---------------------------------------------------------------------------
say "checking the printer power cycle and the A/C load shed (bug 7)"

plug_log="$REAPER_OUT/smoke-plugs.txt"
: > "$plug_log"

# Tell the daemon the A/C is on, so there is a desire worth restoring.
/usr/local/bin/mosquitto_pub -h 127.0.0.1 -r \
    -t 'home/office/plug/climate' -m '{"state":"ON"}' 2>/dev/null
sleep 0.5

# Watch both plug set-topics with timestamps, for the whole cycle.
/usr/local/bin/mosquitto_sub -h 127.0.0.1 -v -W 14 \
    -t 'home/office/plug/+/set' > "$plug_log" 2>/dev/null &
plug_sub=$!
sleep 0.3

/usr/local/bin/mosquitto_pub -h 127.0.0.1 \
    -t 'bubbles/anycubic_kobra_neo/power' -m 'REBOOT' 2>/dev/null

# Echo the plug's own state back, the way a real smart plug does after being
# commanded. THIS IS WHAT MAKES THE MASK MATTER: while shedding, that OFF
# report is our own command coming back, and if the machine records it as the
# desired state then the restore has nothing to restore to and the A/C never
# returns. Without this echo the mask clause was untested -- a mutation that
# deleted it from the shipped config survived the whole battery.
( sleep 2
  /usr/local/bin/mosquitto_pub -h 127.0.0.1 -r \
      -t 'home/office/plug/climate' -m '{"state":"OFF"}' 2>/dev/null ) &

wait "$plug_sub" 2>/dev/null || true

say "plug traffic during the cycle:"
cat "$plug_log" | sed 's/^/      /'

# The printer must have been cut and restored.
grep -q '3d_printer/set {"state":"OFF"}' "$plug_log" \
    || die "the printer was never powered down"
grep -q '3d_printer/set {"state":"ON"}' "$plug_log" \
    || die "the printer was never powered back up after the dwell"
say "printer: OFF then ON across the dwell"

# The A/C must have been shed.
grep -q 'climate/set {"state":"OFF"}' "$plug_log" \
    || die "the A/C was never shed for the printer"
say "A/C shed while the printer was busy"

# BUG 7: the A/C restore must come AFTER the printer came back, not before.
ac_on_line=$(grep -n 'climate/set {"state":"ON"}' "$plug_log" | head -1 | cut -d: -f1)
printer_on_line=$(grep -n '3d_printer/set {"state":"ON"}' "$plug_log" | head -1 | cut -d: -f1)

if [ -z "$ac_on_line" ]; then
    die "the A/C was never restored after the print cycle"
fi

if [ -z "$printer_on_line" ] || [ "$ac_on_line" -lt "$printer_on_line" ]; then
    die "BUG 7: the A/C came back at line $ac_on_line, before the printer at line ${printer_on_line:-never} -- it was restored during the power cycle"
fi

say "A/C restored only AFTER the printer returned (bug 7 is fixed)"

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
