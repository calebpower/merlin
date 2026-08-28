# merlin

A home automation platform for people who want to say *what the house should
do* and not *which topic to publish on*.

merlin runs as a single FreeBSD daemon. It speaks MQTT, HTTP ingress and HTTP
polling; it turns those into a typed model of the house; and it drives rules
written as data over that model. Zigbee devices, a 3D printer, an air
conditioner and a GPS vehicle tracker are what it was built against, but
nothing about any of them is compiled in.

**The platform knows nothing about any particular house.** Zones, devices,
groups and rules all live in one configuration file that merlin validates and
refuses to boot without. The house this was written for is a separate
repository; `priv/example.exs` is a complete fictional one you can read.

## The idea

Elixir modules are **abstraction layers**. Rules are **data**.

A module knows that a HAPN tracker reports `gpsUTCTime`, and that a geofence is
a haversine comparison against a radius with hysteresis. A rule knows only that
`person.owner.zone == :home`. A topic string, a JSON field name or a unit
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
RULES          one :gen_statem per stateful rule      DATA
    v
EFFECTS        resolved effects -> intents -> adapters
```

### Levels and events

A **level** has a current value and notifies only on change
(`door.garage.contact = :open`). An **event** is momentary, has no stored
value, and is delivered every time (`button.living_room.pressed = :double`).

Conflating the two is what forces a system to write timestamps into its state
purely to defeat a value-equality check. Keep them apart.

### Three-valued throughout

Every fact is `value | :unknown`, and `:unknown` propagates through every
operator. A guard fires only on literal `true`, so "we do not know" can never
read as "yes". A fact that has aged past its `stale_after` reads `:unknown`
rather than reporting a stale value as current — which is the difference
between "the car is at home" and "the car was at home when the tracker last
spoke, four hours ago".

## Configuration

One file, evaluated to a plain map and validated before anything starts:

| Key | What it declares |
|---|---|
| `mqtt`, `api` | broker address, listener ports |
| `dry_run` | log every effect instead of performing it |
| `settle_ms` | how long after boot merlin learns without acting |
| `persist` | which fact prefixes survive a restart |
| `zones`, `colocation_distance` | geofence geometry |
| `groups` | named sets of facts; optionally a command target |
| `sources` | topic → fact/event bindings, with codecs |
| `derived` | facts computed from other facts, pollers, geofences |
| `rules` | stateless rules and `:gen_statem` machines |

Validation collects every error rather than stopping at the first, and refuses
unknown keys with a "did you mean". A typo is a refusal to boot, not a daemon
that starts successfully and quietly does nothing.

## Installing

merlin ships as an OTP release with `include_erts: true`, so the target needs
**no Erlang, no Elixir and no compiler** — and a `pkg upgrade` cannot move a
runtime out from under the daemon.

### 1. Build a release

Builds must happen on the same FreeBSD major as the target: the release bundles
the build host's ERTS, which links that host's `libcrypto`, and `exqlite`
compiles a SQLite NIF beside it. Neither cross-builds.

```sh
reaper test          # builds, runs the battery, leaves the tarball in out/
```

or, on a FreeBSD 15.1 machine with the toolchain below:

```sh
MIX_ENV=prod mix release
```

Either way you get `merlind-<version>.tar.gz`.

### 2. Prepare the target

```sh
pw groupadd merlin
pw useradd merlin -g merlin -d /var/db/merlin -s /usr/sbin/nologin \
   -c "merlin home automation daemon"

install -d -o root   -g merlin -m 0750 /usr/local/merlin /usr/local/etc/merlin
install -d -o merlin -g merlin -m 0750 /var/db/merlin /var/db/merlin/tmp
```

`/var/db/merlin` is both the state directory and the daemon's working
directory. It must be writable by `merlin`: the BEAM writes `erl_crash.dump`
there, and without a writable cwd it dies during boot inside the logger with an
error that names nothing useful.

### 3. Unpack

```sh
V=0.4.0
install -d -o root -g merlin -m 0750 /usr/local/merlin/releases/$V
tar -xzf merlind-$V.tar.gz -C /usr/local/merlin/releases/$V
ln -shf /usr/local/merlin/releases/$V /usr/local/merlin/current
```

The `current` symlink is the upgrade mechanism: unpack beside, flip, restart.
Old releases stay where they are and rolling back is flipping it again.

### 4. Configure

```sh
install -o root   -g merlin -m 0640 my-house.exs  /usr/local/etc/merlin/merlin.exs
install -o merlin -g merlin -m 0600 my-secrets.exs /usr/local/etc/merlin/merlin.secrets.exs
```

Start from `priv/example.exs` and `priv/merlin.secrets.exs.example`. The
secrets file is checked for mode 0600 at boot and merlin refuses to start if
anyone else can read it. The config file is *evaluated*, so it is at the same
trust level as the release itself — never point `MERLIN_CONFIG` at anything you
did not write.

### 5. rc.d and logging

```sh
install -o root -g wheel -m 0555 rel/merlind.rc /usr/local/etc/rc.d/merlind
sysrc merlind_enable=YES
```

`merlind` is the daemon; `merlin` is reserved for the command-line interface.
The knobs, all optional:

| rc.conf | Default |
|---|---|
| `merlind_enable` | `NO` |
| `merlind_runas` | `merlin` |
| `merlind_root` | `/usr/local/merlin/current` |
| `merlind_config` | `/usr/local/etc/merlin/merlin.exs` |
| `merlind_state` | `/var/db/merlin` |
| `merlind_trace` | `NO` — log the *names* of what each `/snitch` request carries, never the values |

Give it its own log, because a busy daemon in `/var/log/messages` rotates away
faster than you can read it:

```
# /etc/syslog.conf
!merlind
*.*                                             /var/log/merlind.log

# /etc/newsyslog.conf
/var/log/merlind.log                    644  21    5000  @T00  JC
```

```sh
service syslogd restart
```

### 6. Check, then start

```sh
/usr/local/merlin/current/bin/merlin-preflight
service merlind start
```

Preflight is the same command rc.d runs before every start. It parses and
validates the config, resolves every secret reference, checks the derived-fact
graph for cycles, opens and migrates the database, connects to the broker,
binds the listener ports and loads `:crypto`. It exits non-zero and says why.
Without it a bad config is a restart loop under `daemon -R 5` while you read
logs to work out the reason.

Then:

```sh
fetch -qo- http://127.0.0.1:8080/healthz      # or whatever api.port declares
service merlind status
```

`healthz` answers throughout, including during the settle window. Two more
endpoints bind loopback only, on port 8081: `/facts.json` is everything merlin
currently believes about the house, and `/rules.json` is every rule with the
paths it watches — which is the first place to look when a rule is not firing.

### 7. Ingress keys

The HTTP ingress authenticates by key, and a key *is* a capability for exactly
one topic. Keys are stored hashed; the plaintext is shown once, at mint.

```sh
B=/usr/local/merlin/current/bin
$B/merlin-key add --topic http/mobile/phone/state --label "phone"
$B/merlin-key list
$B/merlin-key rm --id 3
```

`add` takes `--topic`, and optionally `--label` and `--expires <days>`. `rm`
takes `--id`, `--prefix` or `--key`. There is also `import --from <path>` for
a database written by an older, unhashed scheme.

These work whether or not the daemon is running — SQLite in WAL mode lets both
hold the file — so a key can be minted without an outage.

## Toolchain

`exec = "host"` means reaper cannot pin this, so it is pinned here and asserted
by `reaper/build.sh`, which fails the build on drift:

| | Version |
|---|---|
| Erlang/OTP | **28** (major asserted; patch may float) |
| Elixir | **1.19.x** |
| FreeBSD | **15.1-RELEASE** (build guest and target must match) |

Do not use `elixir-devel`. A house should not run on a development-branch
compiler.

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

| Tier | Answers |
|---|---|
| 0 | harness self-test: the things every later tier assumes |
| 1 | pure units — expressions, codecs, geometry, the topic trie |
| 3 | source-as-data: the shipped config, validated as a test |
| 4 | server contract: the ingress authorization matrix |
| 5 | daemon against fakes, with injected transport failures |
| 6 | full stack — real broker, real SQLite, real release |
| 7 | seeded fuzzing of every ingest seam |
| 8 | concurrency, including the CLI writing while the daemon runs |
| 9 | a simulated house against a shadow model and invariant checker |

`reaper/tiers.sh` writes a ledger to `out/tiers.tsv` in which every tier is
`pass`, `FAIL`, or `not-built`. **A tier that is not built is never reported as
a pass.** A battery whose unimplemented half reads as green is the same defect
as an invariant that never fires.

Tiers 2, 10 and 11 are declared not-applicable rather than skipped: 2 and 10
need rendered markup, which arrives with the dashboard; 11 wants a first-time
user to observe, and there is one maintainer.

Every tier-9 invariant has a matching self-test that feeds it a deliberately
broken timeline and requires it to complain — because an invariant that cannot
be made to fail is not evidence.

Reproducing a failure: every seed is written to `out/seed.txt`.

```sh
MERLIN_SEED=1234567890 reaper test
echo 3460 > reaper/sim-seed && reaper test   # pin tier 9's house
```

## Rules are data, and stay data

The expression language is deliberately small: fourteen operators, a hard cap
of **25 builtins**, and no way to reach the host system. It parses without
evaluating and interprets a closed whitelist, so a guard cannot open a file or
spawn a process.

That cap is a guardrail, not a target. Crossing it means the config file is
becoming a programming language with no debugger, no types and no stack traces,
and the answer at that point is to write a module. Anything with I/O, anything
that iterates an unbounded collection, anything stateful across evaluations,
and anything a reasonable person would call an algorithm is a module by
definition — the geofence, the travel-time bound, the OAuth2 token lifecycle
and the four rule executors all are.

## Licence

Copyright 2026 Caleb L. Power

Licensed under the Apache License, Version 2.0. You may not use this work
except in compliance with the License; a copy is in `LICENSE`, and the
canonical text is at <https://www.apache.org/licenses/LICENSE-2.0>.

Every dependency is permissive and none imposes a copyleft term. That is the
whole locked tree — 25 packages, ten direct and fifteen transitive — not just
the ones named in `mix.exs`: twenty are Apache-2.0, and `bandit`, `exqlite`,
`finch`, `thousand_island` and `websock` are MIT.

The audit is meaningful only because `mix.lock` is committed. Without a lock
the tree resolves afresh on every build, and a statement about its licences
would be a statement about whatever happened to install that day.

There are no per-file licence headers. Apache-2.0 recommends them and does not
require them, and in this codebase the top of every module is a `@moduledoc`
carrying the reasoning for what is below it — five lines of boilerplate above
each one would bury the thing most worth reading.

**If you redistribute a built release rather than the source**, note that it
contains more than this project. `include_erts: true` bundles Erlang/OTP
(Apache-2.0) into the tarball, and `exqlite` compiles in SQLite (public
domain). Their terms travel with the binary.
