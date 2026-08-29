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
TRANSPORTS     MQTT · HTTP ingress · pollers            bytes in
    v
ADAPTERS       protocol -> semantic facts/events        CODE
    v
FACT STORE     ETS + single writer; levels vs events    CODE
    v
DERIVED FACTS  declared computations over facts         DATA
    v
RULES          one :gen_statem per stateful rule        DATA
    v
EFFECTS        resolved effects -> intents -> adapters  CODE
```

The right-hand column is the whole point. Two layers are things you *write in
a config file*; the rest is compiled. If you find yourself wanting to put a
topic in the DATA rows or a house rule in the CODE rows, the layering has
slipped.

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

## Configuring it

Everything about your house is one file — an Elixir map, evaluated at boot and
validated before anything starts. `priv/example.exs` is a complete, working
house; copy it and edit. Every snippet below is lifted from it.

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

### 1. Start with the infrastructure

```elixir
%{
  mqtt: %{host: "localhost", port: 1883},
  api: %{port: 8080},

  # Log every effect instead of performing it. Ship TRUE. The first thing a
  # new daemon should do is tell you what it *would* have done.
  dry_run: true,

  # After boot and after every broker reconnect, learn without acting.
  # Retained messages replay in a burst and look exactly like the whole house
  # changing at once; without this your alarms fire every time wifi hiccups.
  settle_ms: 15_000,

  # ... the rest below goes here
}
```

### 2. Find out what your devices actually say

Do not guess topics. Watch the broker:

```sh
mosquitto_sub -h localhost -t '#' -v
```

Press a button, open a door, and read back the topic and payload verbatim.
Getting this wrong is silent — merlin binds a topic nothing ever publishes to
and simply never learns the fact.

### 3. Turn a topic into a fact

A **source** binds one topic filter and says what to pull out of the payload.
`from:` is a path into the decoded body; `codec:` maps the wire value onto the
vocabulary your rules use.

```elixir
sources: [
  %{
    id: :lamp_one,
    topic: "z2m/home/living_room/plug/lamp_1",
    decode: :json,
    facts: [
      %{
        path: [:lamp, :living_room, :one, :power],
        from: [["state"]],
        codec: {:enum, %{"ON" => :on, "OFF" => :off}}
      }
    ]
  }
]
```

That gives you the fact `lamp.living_room.one.power`, which is what a rule
refers to. Codecs available: `:raw`, `:json`, `:integer`, `:float`,
`{:enum, %{"ON" => :on}}`, `{:truthy, if_true, if_false}`,
`{:json_path, path, inner}`, and `{:enum_value, mapping}`.

**Momentary things are events, not facts.** A button press has no resting
value, so declare it under `events:` and it is delivered every time rather
than deduplicated:

```elixir
%{
  id: :living_room_button,
  topic: "z2m/home/living_room/switch/lamps/action",
  decode: :raw,
  events: [
    %{
      path: [:button, :living_room, :pressed],
      codec: {:enum, %{"single" => :single, "double" => :double}}
    }
  ]
}
```

**One source can cover many devices.** A `+name` wildcard captures a topic
segment into the fact path, and the captured value is readable in a rule as
`trigger.name`:

```elixir
%{
  id: :doors,
  topic: "z2m/home/+room/sensor/contact",
  decode: :json,
  facts: [
    %{
      path: [:door, {:capture, "room"}, :contact],
      from: [["contact"]],
      codec: {:truthy, :closed, :open}
    }
  ]
}
```

### 4. Name sets of things

A **group** is a named set of fact paths. With a `set_topic` it is also
something you can command; without one it is purely a set to read.

```elixir
groups: [
  %{
    id: :living_room_lamps,
    members: [[:lamp, :living_room, :one, :power], [:lamp, :living_room, :two, :power]],
    set_topic: "z2m/living_room_lamps/set",
    encode: {:json_state, %{on: "ON", off: "OFF"}}
  },

  # Members only. Nothing is published to "the exterior doors" -- this exists
  # so a rule can say which doors matter without naming a path shape.
  %{
    id: :exterior_doors,
    members: [[:door, "front", :contact], [:door, "back", :contact]]
  }
]
```

### 5. Declare where places are

```elixir
zones: [
  %{id: :home, center: {51.4779, -0.0015}, radius: {0.25, :mi}, hysteresis: 1.25},
  %{id: :workshop, center: {51.5537, -0.0708}, radius: {0.25, :mi}}
],

# Separate from any zone radius: "is the car with my phone" is a different
# question from "how big is my house".
colocation_distance: {0.25, :mi},
```

`hysteresis: 1.25` means you leave at 1.25× the radius you arrived at. It is
not optional in practice — without it a phone parked on the boundary with poor
GPS flaps between states and toggles your lights all evening.

### 6. Compute facts from other facts

A **derived** fact is a declared computation. Four kinds: `:expr`,
`:geofence`, `:sun`, `:http_poll`.

```elixir
derived: [
  %{
    id: :vehicle_with_phone,
    kind: :expr,
    out: [:vehicle, :car, :with_phone?],
    compute: "within?(vehicle.car.position, person.owner.position, 402.34)"
  },

  %{
    id: :owner_zone,
    kind: :geofence,
    lat: [:person, :owner, :lat],
    lon: [:person, :owner, :lon],
    accuracy: [:person, :owner, :accuracy_m],
    max_accuracy_m: 100,
    max_speed: {120, :kph},
    out: [:person, :owner, :zone],
    out_position: [:person, :owner, :position],
    stale_after_ms: 1_800_000
  }
]
```

`out_position` is what makes `person.owner.position` exist — the `:expr`
above reads it. `max_speed` decides how long a fix stays an *answer*: once
somewhere else has been reachable for longer than the fix is old, the zone
becomes `:unknown` rather than standing forever.

Subscriptions are derived from the expression, so there is no watch list to
keep in step — change the expression and what it listens to follows.

Add `hold: {:true_for, {2, :minute}}` to require a condition to stay true
before the fact flips. Going false is immediate: an alarm should be slow to
fire and quick to clear.

### 7. Write the rules

A **stateless rule** is a trigger, an optional guard, and actions.

```elixir
rules: [
  %{
    id: :lamps_toggle,
    desc: "A single press toggles the living room lamps: off only when both are on.",
    on: [{:receives, [:button, :living_room, :pressed]}],
    when: "trigger.value == :single",
    do: [
      {:set_group, :living_room_lamps,
       {:expr, "if(all_eq?(:living_room_lamps, :on), :off, :on)"}}
    ]
  }
]
```

Triggers: `{:changes, path}`, `{:changes_under, prefix}`,
`{:changes_in, group}`, `{:enters, path, value}`, `{:leaves, path, value}`,
`{:receives, event_path}`.

Actions: `{:set_group, group, value}`, `{:publish, topic, payload}`,
`{:set_fact, path, value}`, `{:log, level, message}`,
`{:notify, channel, message}`.

Any action value may be `{:expr, "..."}` instead of a literal. **Forget the
`{:expr, ...}` wrapper and your string is used verbatim** — the validator
refuses a literal containing `trigger.` or `local.` for exactly that reason.

A **stateful rule** is a machine: named states, each with clauses. It is what
you want for latches, timed sequences and anything that must remember.

```elixir
%{
  id: :intruder_latch,
  desc: "If an exterior door moves while I am away, log once. Re-arm when I get home.",
  machine: %{
    initial: :armed,
    persist: true,          # a latch that forgets on restart is not a latch
    states: %{
      armed: [
        %{
          on: {:changes_in, :exterior_doors},
          when: "defined?(person.owner.zone) and person.owner.zone != :home",
          do: [{:notify, :log, {:expr, "\"activity at home: \" + to_s(trigger.room, \"a door\")"}}],
          goto: :fired
        }
      ],
      fired: [
        %{on: {:enters, [:person, :owner, :zone], :home}, do: [{:log, :info, "re-armed"}], goto: :armed}
      ]
    }
  }
}
```

### 8. What you can write in an expression

Facts by dotted path (`person.owner.zone`), `trigger.value` / `trigger.prev` /
`trigger.path` / `trigger.<capture>`, and `local.<slot>` inside a machine.

Operators: `== != < <= > >= and or not in + - * /`. Builtins: `if/3`,
`defined?/1`, `unknown?/1`, `all_eq?/2`, `any_eq?/2`, `count_eq/2`,
`distance/2`, `within?/3`, `to_s/1`, `to_s/2`, `abs/1`.

Two traps worth knowing before you write a guard:

* **Never compare against `:unknown`.** Every operator propagates it, so
  `x != :unknown` is permanently `:unknown` and the rule never fires. Use
  `defined?(x)`. The compiler now refuses the broken spelling.
* **`to_s/1` propagates `:unknown` too**, and an action whose message resolves
  to `:unknown` is skipped entirely. In an alert, that means losing the name
  loses the alert. Use `to_s(value, "fallback")`.

### 9. Secrets, separately

Credentials never go in this file. Reference them and put the values in
`merlin.secrets.exs`, mode 0600:

```elixir
# in merlin.exs
auth: [url: {:secret, :hapn_auth_endpoint}, client_id: {:secret, :hapn_client_id}]
```

```elixir
# in merlin.secrets.exs -- see priv/merlin.secrets.exs.example
%{
  hapn_auth_endpoint: "https://REPLACE/oauth/token",
  hapn_client_id: "REPLACE",
  discord_webhook: "https://discord.com/api/webhooks/REPLACE/REPLACE"
}
```

merlin refuses to start if a referenced secret is missing, or if the secrets
file is readable by anyone else.

### 10. Check it before you run it

```sh
MERLIN_CONFIG=./my-house.exs /usr/local/merlin/current/bin/merlin-preflight
```

This is the test suite for a house. It parses and fully validates the config,
resolves every secret, checks the derived graph for cycles, refuses a guard
naming a zone you never declared, opens the database, connects to the broker
and binds the ports. It is the same command rc.d runs before every start, so a
config that passes here is one the daemon will accept.

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

See **[Configuring it](#configuring-it)** for how to write the house file;
start from `priv/example.exs` and `priv/merlin.secrets.exs.example`.

The secrets file is checked for mode 0600 at boot and merlin refuses to start
if anyone else can read it. The config file is *evaluated*, so it is at the
same trust level as the release itself — never point `MERLIN_CONFIG` at
anything you did not write.

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

## Watching it: `merlin`

The daemon is `merlind`; `merlin` is how you look at it. With no arguments it
opens a terminal interface; with any, it answers and exits.

```sh
merlin                      # the interface
merlin --once               # render one frame to stdout and exit
merlin --once --pane rules  # ...a particular pane, at a chosen size
merlin key list             # one-shot, same as merlin-key
merlin preflight
```

Four panes, on the number keys: **facts** (everything merlin believes, with
how long ago each was last heard from), **rules** (both stateless rules and
state machines, with the state each machine is actually in), **stream** (fact
changes, events, and what became of every effect), and **devices** (groups and
their members' current values).

`j`/`k` move, `/` filters, `:` opens a command line, `q` quits.

    :  set living_room_lamps off      command a group
    :  fact person.cal.zone :home     write a fact by hand
    :  = any_eq?(:exterior_doors, :open)
                                      evaluate an expression against the world

### Nothing typed reaches the house without a confirmation

A command is *parsed*, then *resolved and described*, then run — three steps,
and the description you confirm is generated from the resolved effects rather
than from the text you typed. A mis-keyed binding cannot actuate something you
did not read.

While the daemon is in dry run, `y` confirms and the effect is logged and
discarded. `!` confirms **and overrides dry run for that one command**. Two
keys rather than a mode, because a mode can be left on and this should be
chosen every time.

There is deliberately no runtime dry-run toggle. It is snapshotted in three
places, so flipping it live would leave stateless rules dry while machines ran
live — worse than either extreme, and invisible.

### Where it runs

In its own BEAM on the daemon's host, talking to `merlind` over loopback
distribution. Not inside the daemon: `System.halt/1` is reachable by name from
a CLI, the daemon runs in embedded mode so a UI bug would mean restarting the
house to fix it, and a terminal belongs to the process that owns it.

The client loads every module but starts no application, which means
`Merlin.Config.dry_run?()` answers `false` there. So only `Merlin.TUI.Remote`
may reach daemon state, and a tier 1 test reads the compiled beams to enforce
it — a banner reading LIVE while the daemon is dry is the failure that rule
exists to prevent.

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

Tier 2 covers the terminal interface: a rendered frame is a deterministic
character grid, which is a better conformance surface than markup — no cascade,
no layout engine. It asserts structure (a frame is exactly the rect it was
given; no cell holds a control character), layout against a specification
written in the test rather than imported from the view, and *sensitivity* —
perturb one datum and the frame must move, which is what proves a column is
wired to the screen at all.

Then `Merlin.Test.FrameMutations` corrupts a correct frame eight ways and
requires every corruption to break at least one assertion. A golden file
captured from an implementation blesses whatever that implementation did,
including a marker it never rendered.

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

## License

Copyright 2026 Caleb L. Power

Licensed under the Apache License, Version 2.0. You may not use this work
except in compliance with the License; a copy is in `LICENSE`, and the
canonical text is at <https://www.apache.org/licenses/LICENSE-2.0>.

Every dependency is permissive and none imposes a copyleft term. That is the
whole locked tree — 25 packages, ten direct and fifteen transitive — not just
the ones named in `mix.exs`: twenty are Apache-2.0, and `bandit`, `exqlite`,
`finch`, `thousand_island` and `websock` are MIT.

The audit is meaningful only because `mix.lock` is committed. Without a lock
the tree resolves afresh on every build, and a statement about its licenses
would be a statement about whatever happened to install that day.

There are no per-file license headers. Apache-2.0 recommends them and does not
require them, and in this codebase the top of every module is a `@moduledoc`
carrying the reasoning for what is below it — five lines of boilerplate above
each one would bury the thing most worth reading.

**If you redistribute a built release rather than the source**, note that it
contains more than this project. `include_erts: true` bundles Erlang/OTP
(Apache-2.0) into the tarball, and `exqlite` compiles in SQLite (public
domain). Their terms travel with the binary.
