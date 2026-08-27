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

  The seed is printed on every run and can be pinned with `MERLIN_SIM_SEED`.
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
        publish(2, "home/office/plug/3d_printer/set", ~s({"state":"OFF"})),
        publish(3, "home/office/plug/climate/set", ~s({"state":"OFF"})),
        # The A/C comes back while the printer is still down. This is exactly
        # what office_aircond.py did.
        publish(4, "home/office/plug/climate/set", ~s({"state":"ON"})),
        publish(5, "home/office/plug/3d_printer/set", ~s({"state":"ON"}))
      ]

      assert [msg] = Invariants.ac_off_for_the_whole_cycle(broken)
      assert msg =~ "bug 7"
    end

    test "ac_off_for_the_whole_cycle is quiet on a correct cycle" do
      clean = [
        entry(1, note: "printer reboot requested"),
        publish(2, "home/office/plug/3d_printer/set", ~s({"state":"OFF"})),
        publish(3, "home/office/plug/climate/set", ~s({"state":"OFF"})),
        publish(4, "home/office/plug/3d_printer/set", ~s({"state":"ON"})),
        publish(5, "home/office/plug/climate/set", ~s({"state":"ON"}))
      ]

      assert Invariants.ac_off_for_the_whole_cycle(clean) == []
    end

    test "latch_never_fires_at_home catches a latch firing in the kitchen" do
      broken = [
        entry(1, facts: %{[:rule, :intruder_latch, :state] => :armed}),
        entry(2,
          facts: %{
            [:rule, :intruder_latch, :state] => :fired,
            [:person, :caleb, :zone] => :home
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
            [:person, :caleb, :zone] => :work
          }
        )
      ]

      assert Invariants.latch_never_fires_at_home(clean) == []
    end

    test "latch_stays_fired_until_home catches a latch that forgets" do
      broken = [
        entry(1,
          facts: %{
            [:rule, :intruder_latch, :state] => :fired,
            [:person, :caleb, :zone] => :work
          }
        ),
        entry(2,
          facts: %{
            [:rule, :intruder_latch, :state] => :armed,
            [:person, :caleb, :zone] => :work
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
            [:person, :caleb, :zone] => :work
          }
        ),
        entry(2,
          facts: %{
            [:rule, :intruder_latch, :state] => :armed,
            [:person, :caleb, :zone] => :home
          }
        )
      ]

      assert Invariants.latch_stays_fired_until_home(clean) == []
    end

    test "nothing_published_while_settling catches a hole in the window" do
      broken = [publish(1, "home/office/plug/climate/set", "ON", settling?: true)]

      assert [msg] = Invariants.nothing_published_while_settling(broken)
      assert msg =~ "while still settling"
    end

    test "nothing_published_while_settling is quiet after the window closes" do
      clean = [publish(1, "home/office/plug/climate/set", "ON", settling?: false)]
      assert Invariants.nothing_published_while_settling(clean) == []
    end

    test "lamps_never_commanded_in_daylight catches a daytime arrival" do
      broken = [
        publish(1, "zigbee2mqtt/living_room_lamps/set", ~s({"state":"ON"}),
          facts: %{[:sun, :state] => :day}
        )
      ]

      assert [msg] = Invariants.lamps_never_commanded_in_daylight(broken)
      assert msg =~ "in daylight"
    end

    test "lamps_never_commanded_in_daylight permits the same command after dark" do
      clean = [
        publish(1, "zigbee2mqtt/living_room_lamps/set", ~s({"state":"ON"}),
          facts: %{[:sun, :state] => :night}
        )
      ]

      assert Invariants.lamps_never_commanded_in_daylight(clean) == []
    end

    test "no_command_without_a_reason catches actuation from nothing" do
      broken = [
        publish(1, "home/office/plug/climate/set", "ON"),
        entry(2, note: "a door opened")
      ]

      assert [msg] = Invariants.no_command_without_a_reason(broken)
      assert msg =~ "before anything had happened"
    end

    test "no_command_without_a_reason is quiet when something caused it" do
      clean = [
        entry(1, note: "a door opened"),
        publish(2, "home/office/plug/climate/set", "ON")
      ]

      assert Invariants.no_command_without_a_reason(clean) == []
    end

    # The meta-assertion. If someone adds an invariant and no self-test, this
    # notices -- otherwise the suite grows checks nobody has shown can fail.
    test "every invariant has a self-test that makes it fire" do
      # Each name below is asserted above with a deliberately broken timeline.
      covered =
        MapSet.new([
          :ac_off_for_the_whole_cycle,
          :latch_never_fires_at_home,
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
        entry(1, note: "a door opened", facts: %{[:person, :caleb, :zone] => :home}),
        publish(2, "zigbee2mqtt/living_room_lamps/set", ~s({"state":"ON"}),
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

  @zones %{
    home: {35.9606, -83.9207},
    work: {35.9132, -84.3110},
    gym: {35.9401, -83.9951},
    # Just outside home's entry radius but inside its exit radius: the case
    # hysteresis exists for, and the one a phone with poor accuracy sits on
    # for hours.
    boundary: {35.9617, -83.9207},
    away: {36.5000, -84.5000}
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
                "home/garage/sensor/contact",
                "home/office/plug/climate",
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
    do: SimHouse.device(house, "home/#{room}/sensor/contact", ~s({"state":"#{state}"}))

  defp apply_action(house, {:button, press}, _last),
    do: SimHouse.device(house, "zigbee2mqtt/home/living_room/switch/lamps/action", press)

  defp apply_action(house, {:phone, zone, accuracy}, _last) do
    {lat, lon} = Map.fetch!(@zones, zone)

    SimHouse.device(
      house,
      "http/mobile/ariia/state",
      ~s({"gps_latitude":#{lat},"gps_longitude":#{lon},"gps_accuracy":#{accuracy},"battery_level":80})
    )
  end

  defp apply_action(house, {:climate, state}, _last),
    do: SimHouse.device(house, "home/office/plug/climate", ~s({"state":"#{state}"}), retain: true)

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

        flunk("""
        tier 9 found #{length(violations)} invariant violation(s) with seed #{seed}.

        Violations:
        #{Enum.map_join(violations, "\n", fn {name, msg} -> "  * #{name}: #{msg}" end)}

        #{if complete?, do: "Shrunk trace", else: "PARTIALLY shrunk trace (budget exhausted -- this is not minimal)"} (#{length(shrunk)} of #{length(actions)} actions):
        #{Enum.map_join(shrunk, "\n", &"  #{inspect(&1)}")}

        Replay with: MERLIN_SIM_SEED=#{seed} mix test --only tier9
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
                  "home/garage/sensor/contact",
                  "home/office/plug/climate",
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
            {"home/garage/sensor/contact", ~s({"state":"ON"})},
            {"home/front/sensor/contact", ~s({"state":"ON"})},
            {"home/office/plug/climate", ~s({"state":"ON"})},
            {"moonraker/status/print_stats", ~s({"print_stats":{"state":"printing"}})},
            {"zigbee2mqtt/home/living_room/plug/lamp_1", ~s({"state":"OFF"})},
            {"zigbee2mqtt/home/living_room/plug/lamp_2", ~s({"state":"OFF"})}
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
end
