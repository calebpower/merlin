# merlin

A granular home automation platform. Runs as a FreeBSD daemon on
`merlin.home.arpa`, driving Zigbee devices, a 3D printer, an office A/C and a
GPS vehicle tracker over MQTT.

Being rewritten in Elixir. The Python implementation is still in this tree, at
`merlin/`, and remains the parity reference until cutover.

## The idea

Elixir modules are **abstraction layers**. Rules are **data**.

A module knows that a HAPN tracker reports `gpsUTCTime` and that a geofence is
a haversine comparison against a radius. A rule knows only that
`person.caleb.zone == :home`. A topic string, a JSON field name or a unit
conversion appearing anywhere outside an adapter is a bug in the layering.

```
transports     MQTT · HTTP ingress · pollers          bytes
    v
ADAPTERS       protocol -> semantic facts/events      CODE
    v
FACT STORE     ETS + single writer; levels vs events
    v
DERIVED FACTS  declared computations over facts       DATA
    v
RULES          one :gen_statem per rule               DATA
    v
EFFECTS        resolved effects -> intents -> adapters
```

### Levels and events

A **level** has a current value and notifies only on change
(`door.garage.contact = :open`). An **event** is momentary, has no stored
value, and is delivered every time (`button.living_room.pressed = :double`).

Conflating the two is what forced the Python version to write `time.time()`
floats into its state dict purely to defeat a value-equality check. Keep them
apart.

## Toolchain

`exec = "host"` means reaper cannot pin this for us, so it is pinned here and
asserted by `reaper/build.sh`, which fails the build on drift:

| | Version |
|---|---|
| Erlang/OTP | **28** (major asserted; patch may float) |
| Elixir | **1.19.x** |
| FreeBSD | **15.1-RELEASE** (guest and target must match) |

Do not use `elixir-devel`. A house should not run on a development-branch
compiler, and the 1.20.2/OTP-27 pairing on the development workstation is
currently unbootable — which is precisely the failure mode this table exists
to prevent.

The release is built with `include_erts: true`, so the deployed daemon carries
its own runtime and a `pkg upgrade` on the target cannot move a runtime out
from under it. That is the direct fix for what killed the Python deployment:
the venv was bound to `/usr/local/bin/python3` by symlink, and when that
symlink moved from 3.11 to 3.12 the daemon stopped importing its own package.

## The loop

merlin is a [reaper](https://github.com/calebpower/reaper) tenant. Builds and
the test battery run on disposable `freebsd-15.1` machines — never on the
production host, which carries no compiler.

```sh
reaper up            # clone a freebsd-15.1 guest
reaper test          # sync -> build -> reset -> run
reaper down          # destroy it
```

Results land in `out/`: `toolchain.txt` (what actually built it), `tiers.tsv`
(the tier ledger), `seed.txt`, per-tier logs, and the release tarball.

## Testing

Built to reaper's `docs/testing-methodology.md` — a **portfolio of oracles**,
not a pyramid. Each tier answers a question no cheaper tier can.

`reaper/tiers.sh` writes a ledger to `out/tiers.tsv` in which every tier is
`pass`, `FAIL`, or `not-built`. **A tier that is not built is never reported as
a pass.** A battery whose unimplemented half reads as green is the same defect
as an invariant that never fires.

Tiers 2, 10 and 11 are declared not-applicable rather than skipped: 2 and 10
need rendered markup, which arrives with the dashboard; 11 wants a first-time
user to observe, and there is one maintainer.

Reproducing a failure: every seed is written to `out/seed.txt`.

```sh
MERLIN_SEED=1234567890 reaper test
```

### The acceptance gate

The methodology's final validation is to revert defects you have already fixed
and confirm the harness rediscovers them. This project has a ready-made corpus:
the seven bugs found in the Python during the rewrite survey. Each is assigned
to the tier that must catch it. **A tier that cannot rediscover its assigned
bug is not finished.**

Three of those bugs are code paths that have *never executed in production* —
the intruder alert, the lights-off-when-away rule, and phone location ingest.
Fixing them turns on behaviour with no operational history, which is why both
alerting rules ship pointing at a log notifier for a two-week soak before they
are pointed at Discord.

## Rules are data, and stay data

The expression language is bounded: roughly 17 forms plus `{:call, {M,f,a}}`
as an escape hatch, and a **hard cap of 25 builtins**.

That number is a guardrail, not a target. Crossing it means the config file is
becoming a programming language with no debugger, no types and no stack traces,
and the answer at that point is to write a module instead. Anything with I/O,
anything that iterates an unbounded collection, anything stateful across
evaluations, and anything a reasonable person would call an algorithm is a
module by definition.
