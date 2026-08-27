# The dry-run soak

merlin-ex is deployed on merlin.home.arpa and **running in dry run**. It reads
the house, computes every fact and rule, and logs what it *would* do without
sending anything. Nothing it does can change the state of a light, a plug or a
printer until `dry_run` is turned off.

Deployed 2026-08-27. Intended soak: a fortnight.

## Why a soak at all

Three rules have never executed in production, ever:

  * the intruder latch — gated behind bug 2 (`u_home = ""` compared with
    `is False`), unreachable for the life of the Python daemon;
  * lights-off-when-away — same gate;
  * both vehicle alerts — the flag they keyed on was derived from a single GPS
    reading with no hold window.

Turning them on is turning on paths with no operational history. The soak is
where they demonstrate they behave before they are allowed to actuate anything
or wake anyone.

## What to look at

Everything goes to syslog under the tag `merlin_ex`.

    tail -f /var/log/messages | grep merlin_ex

    # what it would have done to the house
    grep 'merlin_ex.*\[dry-run\]' /var/log/messages

    # the three alerting paths, all pointed at :log for now
    grep -E 'merlin_ex.*(unexpected activity|vehicle unaccounted|away while I am home)' /var/log/messages

    # did it restart
    grep -c 'merlin_ex.*settle: boot' /var/log/messages

Ask the daemon directly:

    S="MERLIN_CONFIG=/usr/local/etc/merlin/merlin.exs MERLIN_STATE_DIR=/var/db/merlin HOME=/var/db/merlin"
    su -m merlin -c "cd /var/db/merlin && $S /usr/local/merlin-ex/current/bin/merlin rpc \
      'Merlin.World.dump() |> Enum.each(&IO.puts(\"#{Merlin.Path.to_string(&1.path)} = #{inspect(&1.value)}\"))'"

    curl -s 127.0.0.1:1880/healthz

## What good looks like

  * `[dry-run]` lines that match what you were doing at the time — lamps when
    you pressed the button, the printer sequence when you rebooted it.
  * A HAPN token refresh roughly every 48 minutes. That is bug 3's fix: the
    Python could only ever refresh reactively, after a 403 had already cost a
    poll.
  * `person.cal.zone` moving `:home` → `:away` → `:workshop` and back, and
    reading `:unknown` only when the phone genuinely cannot be located.
  * Silence from the three alerting rules, unless something actually happened.

## What would end the soak early

Pre-decided, so the decision is not made at 3am:

  * more than one intruder-latch line per genuine absence;
  * any vehicle alert while the car is demonstrably where you left it;
  * more than three restarts in ten minutes (`settle: boot` counts them);
  * the MQTT connection reconnect-looping;
  * `person.cal.zone` flapping between values while the phone sits still.

## Turning it on, after the fortnight

Two edits to `/usr/local/etc/merlin/merlin.exs`, then `service merlin-ex restart`:

  1. `dry_run: true` → `false`. Effects reach the house.
  2. `{:notify, :log, ...}` → `{:notify, :discord, ...}` on the rules you trust.
     The webhook is already configured; it is a one-word change per rule, and
     they can be flipped independently.

Preflight validates the file before the daemon starts, so a typo is a refusal
to start rather than a silently broken rule.

## Rollback

Rehearsed 2026-08-27; it took two seconds.

    service merlin-ex stop
    sysrc merlin_ex_enable=NO

The fact snapshot flushes on the way out, so latches and desired settings
survive. **Note:** the Python daemon is NOT a rollback target — its venv has
been broken since 2026-07-27 (`python3` floated to 3.12 while site-packages
stayed at 3.11). Rolling back means the house has no automation, which is where
it has been since July. `/usr/local/merlin` is untouched and still holds the
original `config.toml` and `merlin.db`; nothing in this deployment writes to it.

## Known, open

  * **The phone had a flat battery at deployment**, so there were no `/snitch`
    requests and every presence fact sat at `:unknown`. The ingest path is
    proven regardless — a manual post with the existing key returned 200 and
    resolved `person.cal.zone` to `:home`. Once it is charged and posting,
    check that presence starts moving; the soak proves nothing about the
    presence rules until it does.

  * Weather is not configured and never was; see the note in `merlin.exs`.

  * Two intermittent test-suite failures on 2026-08-27 (a tier 9 baseline, a
    `merlin-key rm`) both passed on retry with no change. Their output is now
    captured rather than discarded, so a recurrence is diagnosable.
