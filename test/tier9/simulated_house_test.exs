defmodule Merlin.SimulatedHouseTest do
  @moduledoc """
  Tier 9: the whole house, driven by a seeded pseudo-random device population,
  checked against invariants that span the entire run.

  The question no cheaper tier answers: **did anything wrong happen over the
  course of two hundred events**. Bug 7 is invisible to a unit test of the load
  shed and obvious the moment you interleave two machines' output in time; the
  same is true of a latch that re-arms, a settle window with a hole in it, and
  a rule that actuates from nothing.

  Runs against the SHIPPED configuration, not a test house. A simulation of a
  house nobody lives in proves that the engine works, which tiers 1 and 5
  already established. What is being asked here is whether *this* set of rules,
  the ones actually installed, misbehave when events arrive in an order nobody
  thought about.

  ## Determinism

  The seed is printed on every run. Pin it with `MERLIN_SIM_SEED` when running
  `mix test` directly, or by writing it to `reaper/sim-seed` for a reaper run --
  reaper does not forward environment variables into the guest, so the variable
  alone would silently do nothing.
  A failing run reports the seed and the shrunk trace, so a defect found at
  step 173 of a 200-step run is handed back as the four steps that matter.

  ## What this tier does NOT prove

    * `sun.state` comes from the real clock, so whether the after-dark lamp
      rule is exercised at all depends on what time the suite runs. The
      daylight case is covered deterministically in the invariant self-tests
      instead.
    * The broker is a fake. It matches wildcards with its own matcher and
      replays retained messages, but it is not mosquitto -- tier 6 is where
      that claim is tested.
    * Timing is compressed. State timeouts are real but the durations are the
      shipped ones, so a run does not wait ten seconds per printer cycle; the
      cycle is driven and then advanced deliberately.
  """

  use ExUnit.Case, async: false

  @moduletag :tier9
  @moduletag timeout: 900_000

  alias Merlin.Test.{Invariants, SimHouse}

  # ==========================================================================
  # Part one: the invariants must be capable of failing.
  #
  # "An invariant that never fires is indistinguishable from a passing suite."
  # Every invariant is fed a timeline built to break it, and must complain --
  # and then a clean timeline, and must not.
  # ==========================================================================

  defp entry(seq, opts) do
    %{
      seq: seq,
      kind: Keyword.get(opts, :kind, :step),
      topic: Keyword.get(opts, :topic),
      payload: Keyword.get(opts, :payload),
      note: Keyword.get(opts, :note),
      settling?: Keyword.get(opts, :settling?, false),
      facts: Keyword.get(opts, :facts, %{})
    }
  end

  defp publish(seq, topic, payload, opts \\ []) do
    entry(seq, Keyword.merge(opts, kind: :publish, topic: topic, payload: payload))
  end

  describe "the invariants themselves fire" do
    test "ac_off_for_the_whole_cycle catches bug 7" do
      broken = [
        entry(1, note: "printer reboot requested"),
        publish(2, "z2m/home/office/plug/3d_printer/set", ~s({"state":"OFF"})),
        publish(3, "z2m/home/office/plug/climate/set", ~s({"state":"OFF"})),
        # The A/C comes back while the printer is still down. This is exactly
        # what office_aircond.py did.
        publish(4, "z2m/home/office/plug/climate/set", ~s({"state":"ON"})),
        publish(5, "z2m/home/office/plug/3d_printer/set", ~s({"state":"ON"}))
      ]

      assert [msg] = Invariants.ac_off_for_the_whole_cycle(broken)
      assert msg =~ "bug 7"
    end

    test "ac_off_for_the_whole_cycle is quiet on a correct cycle" do
      clean = [
        entry(1, note: "printer reboot requested"),
        publish(2, "z2m/home/office/plug/3d_printer/set", ~s({"state":"OFF"})),
        publish(3, "z2m/home/office/plug/climate/set", ~s({"state":"OFF"})),
        publish(4, "z2m/home/office/plug/3d_printer/set", ~s({"state":"ON"})),
        publish(5, "z2m/home/office/plug/climate/set", ~s({"state":"ON"}))
      ]

      assert Invariants.ac_off_for_the_whole_cycle(clean) == []
    end

    test "latch_never_fires_at_home catches a latch firing in the kitchen" do
      broken = [
        entry(1, facts: %{[:rule, :intruder_latch, :state] => :armed}),
        entry(2,
          facts: %{
            [:rule, :intruder_latch, :state] => :fired,
            [:person, :owner, :zone] => :home
          }
        )
      ]

      assert [msg] = Invariants.latch_never_fires_at_home(broken)
      assert msg =~ "while the phone was home"
    end

    test "latch_never_fires_at_home is quiet when the phone is away" do
      clean = [
        entry(1, facts: %{[:rule, :intruder_latch, :state] => :armed}),
        entry(2,
          facts: %{
            [:rule, :intruder_latch, :state] => :fired,
            [:person, :owner, :zone] => :work
          }
        )
      ]

      assert Invariants.latch_never_fires_at_home(clean) == []
    end

    test "latch_never_fires_on_a_lost_phone catches an alarm with no fix" do
      broken = [
        entry(1, facts: %{[:rule, :intruder_latch, :state] => :armed}),
        entry(2,
          facts: %{
            [:rule, :intruder_latch, :state] => :fired,
            [:person, :owner, :zone] => :unknown
          }
        )
      ]

      assert [msg] = Invariants.latch_never_fires_on_a_lost_phone(broken)
      assert msg =~ ":unknown"
    end

    test "latch_never_fires_on_a_lost_phone permits an alarm when away" do
      # The whole point of :away being separate: this one MUST alarm.
      clean = [
        entry(1, facts: %{[:rule, :intruder_latch, :state] => :armed}),
        entry(2,
          facts: %{
            [:rule, :intruder_latch, :state] => :fired,
            [:person, :owner, :zone] => :away
          }
        )
      ]

      assert Invariants.latch_never_fires_on_a_lost_phone(clean) == []
    end

    test "latch_stays_fired_until_home catches a latch that forgets" do
      broken = [
        entry(1,
          facts: %{
            [:rule, :intruder_latch, :state] => :fired,
            [:person, :owner, :zone] => :work
          }
        ),
        entry(2,
          facts: %{
            [:rule, :intruder_latch, :state] => :armed,
            [:person, :owner, :zone] => :work
          }
        )
      ]

      assert [msg] = Invariants.latch_stays_fired_until_home(broken)
      assert msg =~ "re-armed"
    end

    test "latch_stays_fired_until_home permits re-arming on arrival" do
      clean = [
        entry(1,
          facts: %{
            [:rule, :intruder_latch, :state] => :fired,
            [:person, :owner, :zone] => :work
          }
        ),
        entry(2,
          facts: %{
            [:rule, :intruder_latch, :state] => :armed,
            [:person, :owner, :zone] => :home
          }
        )
      ]

      assert Invariants.latch_stays_fired_until_home(clean) == []
    end

    test "nothing_published_while_settling catches a hole in the window" do
      broken = [publish(1, "z2m/home/office/plug/climate/set", "ON", settling?: true)]

      assert [msg] = Invariants.nothing_published_while_settling(broken)
      assert msg =~ "while still settling"
    end

    test "nothing_published_while_settling is quiet after the window closes" do
      clean = [publish(1, "z2m/home/office/plug/climate/set", "ON", settling?: false)]
      assert Invariants.nothing_published_while_settling(clean) == []
    end

    test "lamps_never_commanded_in_daylight catches a daytime arrival" do
      broken = [
        publish(1, "z2m/living_room_lamps/set", ~s({"state":"ON"}),
          facts: %{[:sun, :state] => :day}
        )
      ]

      assert [msg] = Invariants.lamps_never_commanded_in_daylight(broken)
      assert msg =~ "in daylight"
    end

    test "lamps_never_commanded_in_daylight permits the same command after dark" do
      clean = [
        publish(1, "z2m/living_room_lamps/set", ~s({"state":"ON"}),
          facts: %{[:sun, :state] => :night}
        )
      ]

      assert Invariants.lamps_never_commanded_in_daylight(clean) == []
    end

    test "no_command_without_a_reason catches actuation from nothing" do
      broken = [
        publish(1, "z2m/home/office/plug/climate/set", "ON"),
        entry(2, note: "a door opened")
      ]

      assert [msg] = Invariants.no_command_without_a_reason(broken)
      assert msg =~ "before anything had happened"
    end

    test "no_command_without_a_reason is quiet when something caused it" do
      clean = [
        entry(1, note: "a door opened"),
        publish(2, "z2m/home/office/plug/climate/set", "ON")
      ]

      assert Invariants.no_command_without_a_reason(clean) == []
    end

    test "latch_only_fires_on_an_exterior_door catches a bedroom door alarm" do
      broken = [
        entry(1,
          note: ~s(z2m/home/bedroom/sensor/contact {"state":"OFF"}),
          facts: %{[:rule, :intruder_latch, :state] => :armed}
        ),
        entry(2,
          note: ~s(z2m/home/bedroom/sensor/contact {"state":"ON"}),
          facts: %{[:rule, :intruder_latch, :state] => :fired}
        )
      ]

      assert [msg] =
               Invariants.latch_only_fires_on_an_exterior_door(broken, [
                 [:door, "front", :contact]
               ])

      assert msg =~ "bedroom"
      assert msg =~ "not an exterior door"
    end

    test "latch_only_fires_on_an_exterior_door is quiet for the front door" do
      clean = [
        entry(1,
          note: ~s(z2m/home/front/sensor/contact {"state":"OFF"}),
          facts: %{[:rule, :intruder_latch, :state] => :armed}
        ),
        entry(2,
          note: ~s(z2m/home/front/sensor/contact {"state":"ON"}),
          facts: %{[:rule, :intruder_latch, :state] => :fired}
        )
      ]

      assert Invariants.latch_only_fires_on_an_exterior_door(clean, [[:door, "front", :contact]]) ==
               []
    end

    # An invariant checking membership against nothing passes everything. That
    # is the "silently checks nothing" failure this project has now shipped
    # twice, so it is asserted rather than assumed.
    test "latch_only_fires_on_an_exterior_door refuses to pass on an empty group" do
      timeline = [
        entry(1,
          note: ~s(z2m/home/front/sensor/contact {"state":"OFF"}),
          facts: %{[:rule, :intruder_latch, :state] => :armed}
        ),
        entry(2,
          note: ~s(z2m/home/front/sensor/contact {"state":"ON"}),
          facts: %{[:rule, :intruder_latch, :state] => :fired}
        )
      ]

      assert [msg] = Invariants.latch_only_fires_on_an_exterior_door(timeline, [])
      assert msg =~ "no :exterior_doors members"
    end

    test "tui_never_lies is quiet when the frame tells the truth" do
      # The control. Without it, an invariant that reported nothing whatever
      # would satisfy the two cases below and look rigorous.
      honest = [entry(1, facts: %{[:door, "front", :contact] => :open})]

      assert Invariants.tui_never_lies(honest) == []
    end

    test "tui_never_lies catches a row the frame never drew" do
      # The shape a scroll bug takes: the fact is real, the screen looks fine,
      # and the row simply is not there. An operator reads a house with one
      # fewer door than it has.
      timeline = [entry(1, facts: %{[:door, "front", :contact] => :open})]

      dropped = fn _facts -> "" end

      assert [message] = Invariants.tui_never_lies(timeline, dropped)
      assert message =~ "door.front.contact"
    end

    test "tui_never_lies catches a value formatted from somewhere else" do
      # The defect an operator cannot catch: well-formed, correctly laid out,
      # and wrong. It does not look like a fault -- it looks like a house
      # behaving oddly, and they go and investigate the house.
      timeline = [entry(1, facts: %{[:door, "front", :contact] => :open})]

      lying = fn _facts -> "door.front.contact  :closed" end

      assert [message] = Invariants.tui_never_lies(timeline, lying)
      assert message =~ ":open", "the complaint must name the value that was true"
    end

    # The meta-assertion. If someone adds an invariant and no self-test, this
    # notices -- otherwise the suite grows checks nobody has shown can fail.
    test "every invariant has a self-test that makes it fire" do
      # Each name below is asserted above with a deliberately broken timeline.
      covered =
        MapSet.new([
          :ac_off_for_the_whole_cycle,
          :latch_never_fires_at_home,
          :latch_never_fires_on_a_lost_phone,
          :latch_only_fires_on_an_exterior_door,
          :tui_never_lies,
          :latch_stays_fired_until_home,
          :nothing_published_while_settling,
          :lamps_never_commanded_in_daylight,
          :no_command_without_a_reason
        ])

      declared = MapSet.new(Invariants.all(), &elem(&1, 0))

      assert MapSet.difference(declared, covered) |> MapSet.to_list() == [],
             "an invariant exists with no test proving it can fail"

      assert MapSet.difference(covered, declared) |> MapSet.to_list() == [],
             "a self-test names an invariant that no longer exists"
    end

    test "a clean timeline violates nothing at all" do
      clean = [
        entry(1, note: "a door opened", facts: %{[:person, :owner, :zone] => :home}),
        publish(2, "z2m/living_room_lamps/set", ~s({"state":"ON"}),
          facts: %{[:sun, :state] => :night}
        )
      ]

      assert Invariants.check(clean) == []
    end
  end

  # ==========================================================================
  # Part two: the house itself, driven by a seeded device population.
  # ==========================================================================

  # Exterior and interior, because only exterior doors alarm.
  @rooms ["garage", "front", "back", "bedroom"]

  # The real geometry, from the house rather than from imagination.
  @zones %{
    home: {51.4779, -0.0015},
    hackspace: {51.5537, -0.0708},
    # Just outside home's entry radius but inside its exit radius: the case
    # hysteresis exists for, and the one a phone with poor accuracy sits on
    # for hours.
    boundary: {51.4819417, -0.0015},
    away: {43.0000, -71.5000}
  }

  defp seed do
    case System.get_env("MERLIN_SIM_SEED") do
      nil -> :erlang.unique_integer([:positive]) |> rem(100_000)
      raw -> String.to_integer(raw)
    end
  end

  # The action alphabet. Every entry is a pure description, so a trace can be
  # printed, shrunk, and replayed -- which is the whole reason the generator
  # produces data rather than calling the house directly.
  defp gen_action(rand) do
    {roll, rand} = :rand.uniform_s(100, rand)

    {action, rand} =
      cond do
        roll <= 30 ->
          {room, rand} = pick(@rooms, rand)
          {state, rand} = pick(["ON", "OFF"], rand)
          {{:door, room, state}, rand}

        roll <= 45 ->
          {press, rand} = pick(["single", "double"], rand)
          {{:button, press}, rand}

        roll <= 60 ->
          {zone, rand} = pick(Map.keys(@zones), rand)
          {accuracy, rand} = pick([5, 30, 120], rand)
          {{:phone, zone, accuracy}, rand}

        roll <= 70 ->
          {state, rand} = pick(["ON", "OFF"], rand)
          {{:climate, state}, rand}

        roll <= 78 ->
          {job, rand} = pick(["printing", "standby", "complete"], rand)
          {{:print_job, job}, rand}

        roll <= 84 ->
          {{:printer_reboot}, rand}

        roll <= 90 ->
          {{:reconnect}, rand}

        roll <= 96 ->
          # The nemesis: payloads no device would send, on topics the daemon
          # subscribes to. None of these may crash anything or actuate.
          {payload, rand} =
            pick(
              [
                "",
                "not json at all",
                "{",
                ~s({"state":null}),
                ~s({"state":{"nested":"object"}}),
                ~s([1,2,3]),
                <<0xFF, 0xFE, 0x00>>
              ],
              rand
            )

          {topic, rand} =
            pick(
              [
                "z2m/home/garage/sensor/contact",
                "z2m/home/office/plug/climate",
                "http/mobile/ariia/state",
                "moonraker/status/print_stats"
              ],
              rand
            )

          {{:malformed, topic, payload}, rand}

        true ->
          {{:duplicate}, rand}
      end

    {action, rand}
  end

  defp pick(list, rand) do
    {i, rand} = :rand.uniform_s(length(list), rand)
    {Enum.at(list, i - 1), rand}
  end

  defp apply_action(house, {:door, room, state}, _last),
    do: SimHouse.device(house, "z2m/home/#{room}/sensor/contact", ~s({"state":"#{state}"}))

  defp apply_action(house, {:button, press}, _last),
    do: SimHouse.device(house, "z2m/home/living_room/switch/lamps/action", press)

  defp apply_action(house, {:phone, zone, accuracy}, _last) do
    {lat, lon} = Map.fetch!(@zones, zone)

    SimHouse.device(
      house,
      "http/mobile/ariia/state",
      ~s({"gps_latitude":#{lat},"gps_longitude":#{lon},"gps_accuracy":#{accuracy},"battery_level":80})
    )
  end

  defp apply_action(house, {:climate, state}, _last),
    do: SimHouse.device(house, "z2m/home/office/plug/climate", ~s({"state":"#{state}"}), retain: true)

  defp apply_action(house, {:print_job, job}, _last),
    do: SimHouse.device(house, "moonraker/status/print_stats", ~s({"print_stats":{"state":"#{job}"}}))

  defp apply_action(house, {:printer_reboot}, _last) do
    house
    |> SimHouse.device("bubbles/anycubic_kobra_neo/power", "REBOOT")
    # The dwell is genuinely ten seconds in the shipped config, and the whole
    # point of the bug 7 invariant is what happens ACROSS it -- so the run
    # actually waits it out rather than pretending.
    |> SimHouse.wait(10_600)
  end

  defp apply_action(house, {:reconnect}, _last), do: SimHouse.reconnect(house)

  defp apply_action(house, {:malformed, topic, payload}, _last),
    do: SimHouse.device(house, topic, payload)

  defp apply_action(house, {:duplicate}, nil), do: house
  defp apply_action(house, {:duplicate}, last), do: apply_action(house, last, nil)

  defp run_trace(actions, seed) do
    house = SimHouse.start(seed: seed)

    try do
      actions
      |> Enum.reduce({house, nil}, fn action, {house, last} ->
        {apply_action(house, action, last), action}
      end)
      |> elem(0)
      |> SimHouse.timeline()
    after
      SimHouse.stop(house)
    end
  end

  # Delta debugging. A defect found at step 47 of a 60-step run is useless as a
  # bug report and obvious as four steps, so a failing trace is reduced by
  # removing actions for as long as the violation survives.
  #
  # BUDGETED, because each candidate re-runs a whole house and a printer reboot
  # inside it genuinely waits ten seconds. An unbounded shrinker would blow the
  # test timeout and report "timed out" instead of the violation it had already
  # found -- turning a useful failure into a useless one. When the budget runs
  # out it says so rather than presenting a partial reduction as minimal.
  # Twelve, not twenty-five. Each candidate re-runs a whole house, and a
  # printer reboot inside one genuinely waits ten seconds -- so the budget is
  # a wall-clock decision, not a thoroughness one. A partial reduction that
  # arrives is worth more than a minimal one that gets killed.
  @shrink_budget 12

  defp shrink(actions, seed) do
    {shrunk, remaining} = shrink_pass(actions, seed, @shrink_budget)
    {shrunk, remaining > 0}
  end

  defp shrink_pass(actions, seed, budget) do
    Enum.reduce(0..(length(actions) - 1)//1, {actions, budget}, fn i, {candidate, budget} ->
      cond do
        budget <= 0 -> {candidate, 0}
        i >= length(candidate) -> {candidate, budget}
        length(candidate) <= 1 -> {candidate, budget}
        true ->
          shorter = List.delete_at(candidate, i)

          if Invariants.check(run_trace(shorter, seed)) != [] do
            {shorter, budget - 1}
          else
            {candidate, budget - 1}
          end
      end
    end)
  end

  describe "the house under a seeded device population" do
    @tag :tier9
    test "no invariant is violated across a long run" do
      seed = seed()

      # Printed unconditionally, not only on failure. A seed you can only see
      # when something breaks is a seed you cannot use to reproduce the run
      # that nearly broke.
      IO.puts("\n  tier 9 seed: #{seed}  (pin with MERLIN_SIM_SEED=#{seed})")

      {actions, _rand} =
        Enum.reduce(1..60, {[], :rand.seed_s(:exsss, {seed, 0, 0})}, fn _i, {acc, rand} ->
          {action, rand} = gen_action(rand)
          {[action | acc], rand}
        end)

      actions = Enum.reverse(actions)
      timeline = run_trace(actions, seed)
      violations = Invariants.check(timeline)

      if violations != [] do
        # Printed BEFORE shrinking. Shrinking re-runs whole houses and can take
        # minutes; if it overruns the timeout, the violation it already found
        # must still be on the record rather than lost behind "test timed out".
        IO.puts("""

          tier 9 VIOLATIONS with seed #{seed}:
        #{Enum.map_join(violations, "\n", fn {name, msg} -> "    * #{name}: #{msg}" end)}

          shrinking (budget #{@shrink_budget} runs)...
        """)

        {shrunk, complete?} = shrink(actions, seed)
        fixture = save_trace(shrunk, seed, violations, complete?)

        flunk("""
        tier 9 found #{length(violations)} invariant violation(s) with seed #{seed}.

        Violations:
        #{Enum.map_join(violations, "\n", fn {name, msg} -> "  * #{name}: #{msg}" end)}

        #{if complete?, do: "Shrunk trace", else: "PARTIALLY shrunk trace (budget exhausted -- this is not minimal)"} (#{length(shrunk)} of #{length(actions)} actions):
        #{Enum.map_join(shrunk, "\n", &"  #{inspect(&1)}")}

        The trace is written to #{fixture}, which comes back with this run's
        results. Commit it: the SEED does not reproduce this on its own -- it
        fixes the sequence of device actions, not the scheduler -- and a trace
        that lives only in a log is deleted by the next run.

        Replay in a reaper session with:
            echo #{seed} > reaper/sim-seed && reaper test
        or directly:
            MERLIN_SIM_SEED=#{seed} mix test --only tier9
        """)
      end

      # The run must have actually done something. A generator that produced
      # nothing, or a house that ignored everything, would satisfy every
      # invariant perfectly.
      assert length(timeline) > length(actions),
             "the house published nothing at all across #{length(actions)} events"
    end

    test "a malformed payload storm changes nothing and crashes nothing" do
      # Tier 7 fuzzes the ingest boundary for crashes. The question here is
      # different and only answerable with a whole house: does garbage
      # ACTUATE anything.
      house = SimHouse.start(seed: 99)

      try do
        house =
          Enum.reduce(
            [
              "",
              "{",
              "not json",
              ~s({"state":null}),
              ~s({"state":[]}),
              <<0xFF, 0xFE>>,
              String.duplicate("x", 10_000)
            ],
            house,
            fn payload, house ->
              Enum.reduce(
                [
                  "z2m/home/garage/sensor/contact",
                  "z2m/home/office/plug/climate",
                  "http/mobile/ariia/state",
                  "bubbles/anycubic_kobra_neo/power",
                  "moonraker/status/print_stats"
                ],
                house,
                &SimHouse.device(&2, &1, payload)
              )
            end
          )

        timeline = SimHouse.timeline(house)

        commanded =
          timeline
          |> Enum.filter(&(&1.kind == :publish))
          |> Enum.reject(&(&1.topic == "test/pong"))

        assert commanded == [],
               "garbage actuated the house: #{inspect(Enum.map(commanded, & &1.topic))}"

        assert Invariants.check(timeline) == []
        assert Process.alive?(Process.whereis(Merlin.Rules.Engine))
        assert Process.alive?(Process.whereis(Merlin.MQTT.Connection))
      after
        SimHouse.stop(house)
      end
    end

    test "a retained burst on reconnect actuates nothing" do
      # Bug 8, as a property rather than a smoke step: every retained message
      # replays at once, and the house must absorb all of it silently.
      house =
        SimHouse.start(
          seed: 7,
          retained: [
            {"z2m/home/garage/sensor/contact", ~s({"state":"ON"})},
            {"z2m/home/front/sensor/contact", ~s({"state":"ON"})},
            {"z2m/home/office/plug/climate", ~s({"state":"ON"})},
            {"moonraker/status/print_stats", ~s({"print_stats":{"state":"printing"}})},
            {"z2m/home/living_room/plug/lamp_1", ~s({"state":"OFF"})},
            {"z2m/home/living_room/plug/lamp_2", ~s({"state":"OFF"})}
          ]
        )

      try do
        house = SimHouse.reconnect(house)
        timeline = SimHouse.timeline(house)

        during_settle =
          Enum.filter(timeline, &(&1.kind == :publish and &1.settling?))

        assert during_settle == [],
               "the retained burst actuated: #{inspect(Enum.map(during_settle, & &1.topic))}"

        assert Invariants.check(timeline) == []

        # And the facts DID arrive -- a settle window that also discarded
        # observations would pass the assertion above while leaving the daemon
        # ignorant, which is worse than the problem it solves.
        facts = List.last(timeline).facts
        assert Map.get(facts, [:climate, :office, :power]) == :on
        assert Map.get(facts, [:door, "garage", :contact]) == :open
      after
        SimHouse.stop(house)
      end
    end
  end

  # Write the shrunk trace where it will survive.
  #
  # Shrinking costs minutes and produces the one thing that actually explains a
  # failure -- and it used to go into out/tier-9.log, which build.sh clears at
  # the start of the next run. An intermittent violation was lost exactly that
  # way, and re-running under the recorded seed did not bring it back, because
  # a seed fixes the ACTIONS and not the scheduler.
  #
  # So the trace is written as a term file: it comes back with this run's
  # results and can be committed as a regression case. A trace replays the
  # actions deterministically even when the interleaving does not cooperate,
  # which is the difference between "we saw something once" and "here is the
  # case".
  defp save_trace(shrunk, seed, violations, complete?) do
    dir = System.get_env("REAPER_OUT") || Path.join(System.tmp_dir!(), "merlin")
    File.mkdir_p!(dir)
    path = Path.join(dir, "FAILED-tier9-trace-seed-#{seed}.exs")
    names = Enum.map(violations, &elem(&1, 0))

    File.write!(path, """
    # A tier 9 trace that violated an invariant. Committable as a regression
    # case: feed `actions` to the house in order and re-check the invariants.
    #
    # seed:   #{seed}
    # shrunk: #{if complete?, do: "yes", else: "no -- budget exhausted, not minimal"}
    # found:  #{DateTime.utc_now() |> DateTime.to_iso8601()}
    %{
      seed: #{seed},
      shrunk?: #{complete?},
      violations: #{inspect(names)},
      actions: #{inspect(shrunk, limit: :infinity, pretty: true)}
    }
    """)

    path
  end
end
