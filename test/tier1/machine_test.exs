defmodule Merlin.MachineTest do
  @moduledoc """
  Tier 1: the state machines.

  ## Timing without sleeping

  Durations are declared in the machine data and canonicalised at compile time,
  so a test writes `{20, :millisecond}` where production writes
  `{10, :second}` and exercises **the identical `:state_timeout`**. The dwell
  test finishes in about 25ms while testing real `:gen_statem` timing, real
  transitions and real ordering.

  That is the payoff of the machine being data. The alternative -- sleeping
  ten seconds, or mocking the clock -- is either slow or tests something other
  than the code that will run.

  ## Ordering is the content

  A sequence that emits ON then OFF has done the opposite of its job while
  producing the same set of effects. So the assertions are on order, via an
  effects observer that receives them as the clause produced them.
  """

  use ExUnit.Case, async: false

  @moduletag :tier1

  alias Merlin.{Bus, Change, Event, Machine, World}
  alias Merlin.Machine.Server

  setup do
    Application.put_env(:merlin, :effects_observer, self())

    # dry_run TRUE. The observer receives effects before the dry-run branch, so
    # everything is still visible -- and these tests are about what the machine
    # DECIDED, not about whether a broker connection accepted it. Performing
    # them would need an MQTT connection that a unit tier has no business
    # requiring.
    Application.put_env(:merlin, :dry_run, true)
    on_exit(fn -> Application.delete_env(:merlin, :effects_observer) end)
    :ok
  end

  defp uniq, do: System.unique_integer([:positive])

  defp start(data) do
    {:ok, machine} = Machine.compile(data)
    {:ok, pid} = Server.start_link(machine)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    {machine, pid}
  end

  # Publish a change the way the world would, so the machine's subscription is
  # exercised rather than bypassed.
  defp change(path, new, old \\ nil) do
    Bus.publish(%Change{
      path: path,
      old: old,
      new: new,
      at: 0,
      source: :test,
      seq: uniq(),
      first?: is_nil(old)
    })
  end

  defp emit(path, payload) do
    Bus.emit(%Event{path: path, payload: payload, at: 0, source: :test})
  end

  # --- compilation ----------------------------------------------------------

  describe "compilation refuses structurally broken machines" do
    test "a goto naming a state that does not exist" do
      # This would wedge the machine the first time that clause fired, months
      # later, at 3am. Boot instead.
      assert {:error, {:m, {:goto_undefined_state, [{:idle, :nowhere}]}}} =
               Machine.compile(%{
                 id: :m,
                 machine: %{
                   initial: :idle,
                   states: %{idle: [%{on: {:changes, [:a]}, goto: :nowhere}]}
                 }
               })
    end

    test "an initial state that does not exist" do
      assert {:error, {:m, {:initial_state_undefined, :nope}}} =
               Machine.compile(%{
                 id: :m,
                 machine: %{initial: :nope, states: %{idle: [%{on: {:changes, [:a]}}]}}
               })
    end

    test "a set: writing a slot that data: never declared" do
      # Otherwise the slot springs into existence, is readable as :unknown
      # forever, and the typo is invisible.
      assert {:error, {:m, {:undeclared_slots, [{:idle, :typo}]}}} =
               Machine.compile(%{
                 id: :m,
                 machine: %{
                   initial: :idle,
                   data: %{desired: :off},
                   states: %{idle: [%{on: {:changes, [:a]}, set: %{typo: :on}}]}
                 }
               })
    end

    test "a machine with no states" do
      assert {:error, {:m, :no_states}} =
               Machine.compile(%{id: :m, machine: %{initial: :idle, states: %{}}})
    end

    test "a clause with no trigger" do
      assert {:error, {:m, {:idle, 0, :clause_has_no_trigger}}} =
               Machine.compile(%{id: :m, machine: %{initial: :idle, states: %{idle: [%{}]}}})
    end

    test "a guard that will not compile, named with its state and clause index" do
      assert {:error, {:m, {:idle, 0, {:bad_guard, _, _}}}} =
               Machine.compile(%{
                 id: :m,
                 machine: %{
                   initial: :idle,
                   states: %{idle: [%{on: {:changes, [:a]}, when: "System.cmd(\"x\", [])"}]}
                 }
               })
    end

    test "durations canonicalise to milliseconds" do
      assert Machine.to_ms({10, :second}) == {:ok, 10_000}
      assert Machine.to_ms({2, :minute}) == {:ok, 120_000}
      assert Machine.to_ms({1, :hour}) == {:ok, 3_600_000}
      assert Machine.to_ms({20, :millisecond}) == {:ok, 20}
      assert {:error, {:bad_duration, _}} = Machine.to_ms({10, :fortnight})
    end

    test "watches are derived from triggers and guards, never written" do
      {:ok, m} =
        Machine.compile(%{
          id: :m,
          machine: %{
            initial: :idle,
            states: %{
              idle: [%{on: {:changes, [:a, :b]}, when: "c.d == :x"}],
              other: [%{on: {:receives, [:e, :f]}}]
            }
          }
        })

      assert Enum.sort(m.watches) == [[:a, :b], [:c, :d]]
      assert m.watch_events == [[:e, :f]]
    end
  end

  # --- the printer sequence -------------------------------------------------

  describe "a timed sequence (the printer power cycle)" do
    defp printer_machine(id, topic) do
      %{
        id: id,
        desc: "test printer",
        machine: %{
          initial: :idle,
          states: %{
            idle: [
              %{
                on: {:receives, [:printer, id, :request]},
                when: "trigger.value == :reboot",
                do: [{:publish, topic, "OFF"}],
                goto: :dwell
              }
            ],
            dwell: [
              %{on: {:after, {20, :millisecond}}, do: [{:publish, topic, "ON"}], goto: :idle},
              %{on: {:receives, [:printer, id, :request]}, postpone: true}
            ]
          }
        }
      }
    end

    test "emits OFF, waits, then ON — in that order" do
      id = :"printer_#{uniq()}"
      {_m, _pid} = start(printer_machine(id, "plug/set"))

      emit([:printer, id, :request], :reboot)

      assert_receive {:effects, ^id, [{:publish, "plug/set", "OFF", _}]}, 500
      assert_receive {:effects, ^id, [{:publish, "plug/set", "ON", _}]}, 500
    end

    test "the ON does not arrive before the dwell has elapsed" do
      id = :"printer_#{uniq()}"
      {_m, _pid} = start(printer_machine(id, "plug/set"))

      emit([:printer, id, :request], :reboot)
      assert_receive {:effects, ^id, [{:publish, _, "OFF", _}]}, 500

      # Nothing for the first few milliseconds of a 20ms dwell.
      refute_receive {:effects, ^id, [{:publish, _, "ON", _}]}, 5
      assert_receive {:effects, ^id, [{:publish, _, "ON", _}]}, 500
    end

    test "the machine is in :dwell during the wait and :idle after" do
      id = :"printer_#{uniq()}"
      {_m, _pid} = start(printer_machine(id, "plug/set"))

      emit([:printer, id, :request], :reboot)
      assert_receive {:effects, ^id, [{:publish, _, "OFF", _}]}, 500
      assert Server.state(id) == :dwell

      assert_receive {:effects, ^id, [{:publish, _, "ON", _}]}, 500
      assert Server.state(id) == :idle
    end

    test "a request arriving mid-cycle is postponed, not dropped" do
      # The Python's asyncio.sleep(10) had nothing to say about this: a second
      # request during the wait was simply processed concurrently.
      id = :"printer_#{uniq()}"
      {_m, _pid} = start(printer_machine(id, "plug/set"))

      emit([:printer, id, :request], :reboot)
      assert_receive {:effects, ^id, [{:publish, _, "OFF", _}]}, 500

      # Arrives during the dwell.
      emit([:printer, id, :request], :reboot)

      assert_receive {:effects, ^id, [{:publish, _, "ON", _}]}, 500

      # ...and is then handled, starting a second cycle rather than vanishing.
      assert_receive {:effects, ^id, [{:publish, _, "OFF", _}]}, 500
    end

    test "the machine's state is published as a fact" do
      id = :"printer_#{uniq()}"
      {_m, _pid} = start(printer_machine(id, "plug/set"))

      # :gen_statem runs the :enter callback AFTER init/1 returns, so reading
      # immediately after start_link can beat the publish. Asserting the
      # eventual value rather than an instantaneous one -- the claim is that
      # the state IS published, not that it is published synchronously with
      # process start, which was never true.
      assert_eventually(fn -> World.get([:rule, id, :state]) == :idle end)
    end
  end

  # --- the load shed --------------------------------------------------------

  describe "load shed with a remembered desire (the office A/C)" do
    defp shed_machine(id, ac_path, busy_path, topic) do
      %{
        id: id,
        desc: "test load shed",
        machine: %{
          initial: :idle,
          data: %{desired: :off},
          states: %{
            idle: [
              %{on: {:changes, ac_path}, set: %{desired: {:expr, "local_ac_value"}}},
              %{
                on: {:enters, busy_path, true},
                set: %{desired: {:expr, "local_ac_value"}},
                do: [{:publish, topic, "OFF"}],
                goto: :shedding
              }
            ],
            shedding: [
              # THE MASK: an OFF report while shedding is our own command.
              %{on: {:changes, ac_path}, when: "local_ac_value == :off"},
              %{
                on: {:leaves, busy_path, true},
                when: "local.desired == :on",
                do: [{:publish, topic, "ON"}],
                goto: :idle
              },
              %{on: {:leaves, busy_path, true}, goto: :idle}
            ]
          }
        }
      }
    end

    setup do
      # A single-segment fact the guards can name, since expressions address
      # facts by dotted path and the test paths are generated.
      %{ac: [:local_ac_value], busy: [:local_busy]}
    end

    test "remembers ON, sheds, and restores it", %{ac: ac, busy: busy} do
      id = :"shed_#{uniq()}"
      {_m, _pid} = start(shed_machine(id, ac, busy, "ac/set"))

      World.put(ac, :on)
      change(ac, :on)
      assert_eventually(fn -> Server.data(id)[:desired] == :on end)

      change(busy, true, false)
      assert_receive {:effects, ^id, [{:publish, "ac/set", "OFF", _}]}, 500
      assert Server.state(id) == :shedding

      change(busy, false, true)
      assert_receive {:effects, ^id, [{:publish, "ac/set", "ON", _}]}, 500
      assert Server.state(id) == :idle
    end

    test "an OFF report while shedding does NOT overwrite the remembered desire" do
      # The subtlest behaviour in the Python and the reason the mask exists.
      # Without it the plug's own echo becomes the remembered value and the
      # restore is a no-op -- the A/C simply never comes back on.
      ac = [:local_ac_value]
      busy = [:local_busy]
      id = :"shed_#{uniq()}"
      {_m, _pid} = start(shed_machine(id, ac, busy, "ac/set"))

      World.put(ac, :on)
      change(ac, :on)
      assert_eventually(fn -> Server.data(id)[:desired] == :on end)

      change(busy, true, false)
      assert_receive {:effects, ^id, [{:publish, _, "OFF", _}]}, 500

      # The plug reports OFF -- our own command coming back.
      World.put(ac, :off)
      change(ac, :off, :on)
      Process.sleep(20)

      assert Server.data(id)[:desired] == :on,
             "the plug's echo overwrote the remembered desire; the restore would be a no-op"

      change(busy, false, true)
      assert_receive {:effects, ^id, [{:publish, _, "ON", _}]}, 500
    end

    test "does not restore what was already off", %{ac: ac, busy: busy} do
      id = :"shed_#{uniq()}"
      {_m, _pid} = start(shed_machine(id, ac, busy, "ac/set"))

      World.put(ac, :off)
      change(ac, :off)

      change(busy, true, false)
      assert_receive {:effects, ^id, [{:publish, _, "OFF", _}]}, 500

      change(busy, false, true)
      refute_receive {:effects, ^id, [{:publish, _, "ON", _}]}, 100
      assert Server.state(id) == :idle
    end
  end

  # --- the latch ------------------------------------------------------------

  describe "a latch (the intruder alert)" do
    defp latch_machine(id, trigger_path, rearm_path) do
      %{
        id: id,
        desc: "test latch",
        machine: %{
          initial: :armed,
          states: %{
            armed: [
              %{on: {:changes, trigger_path}, do: [{:log, :warning, "fired"}], goto: :fired}
            ],
            fired: [
              %{on: {:enters, rearm_path, :home}, goto: :armed}
            ]
          }
        }
      }
    end

    test "fires once per absence, however many doors move" do
      id = :"latch_#{uniq()}"
      door = [:"door_#{uniq()}"]
      zone = [:"zone_#{uniq()}"]
      {_m, _pid} = start(latch_machine(id, door, zone))

      change(door, :open, :closed)
      assert_receive {:effects, ^id, [{:log, :warning, "fired"}]}, 500

      change(door, :closed, :open)
      change(door, :open, :closed)
      refute_receive {:effects, ^id, _}, 100
      assert Server.state(id) == :fired
    end

    test "re-arms on returning home, and can fire again" do
      id = :"latch_#{uniq()}"
      door = [:"door_#{uniq()}"]
      zone = [:"zone_#{uniq()}"]
      {_m, _pid} = start(latch_machine(id, door, zone))

      change(door, :open, :closed)
      assert_receive {:effects, ^id, _}, 500

      change(zone, :home, :work)
      assert_eventually(fn -> Server.state(id) == :armed end)

      change(door, :open, :closed)
      assert_receive {:effects, ^id, [{:log, :warning, "fired"}]}, 500
    end
  end

  defp assert_eventually(fun, attempts \\ 50) do
    result =
      Enum.reduce_while(1..attempts, false, fn _, _ ->
        if fun.(), do: {:halt, true}, else: (Process.sleep(10); {:cont, false})
      end)

    assert result, "condition never became true"
  end
end
