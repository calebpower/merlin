defmodule Merlin.EffectsTapTest do
  @moduledoc """
  Tier 1: what became of each effect, and who caused it.

  The log has always said what merlin *decided*. Which of three branches wrote
  the line carried the outcome, and only to a human reading it: a dry-run
  discard, a settle-window hold and a dispatch that failed all produced a
  message about the same effect, and a dispatch that *succeeded* produced no
  message at all. `do_perform/3` returned whatever `Logger.warning/1` happened
  to return, so the one thing a caller most wanted to know -- did it work --
  was the one thing thrown away.

  These assert the outcome as a value, because a value can be tested and a
  reader's impression of a log line cannot.

  ## What this tier does not prove

  That an effect which reports `:performed` actually reached the broker. That
  needs a broker and belongs to tier 6; the two effects exercised here for
  success (`:log` and `notify :log`) dispatch to the logger and nowhere else,
  deliberately, so this tier needs no transport at all.

  ## The half of that paragraph which was a bug, not a limitation

  "a dispatch that *succeeded* produced no message at all" was written above as
  a description of the OLD code, and stayed true of the new code for the whole
  soak, because fixing the outcome as a *value* for the tap was mistaken for
  fixing it. It was not: nothing wrote a log line when an effect worked. In dry
  run that is invisible -- the dry-run branch logs -- so the daemon read as
  fully narrated right up until `dry_run` was turned off, at which point the
  log went silent and the house started actually moving.

  The positive case needs a broker and lives in tier 6. What lives here is the
  half that does not: an effect whose whole content is a log line must not be
  announced a second time.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Logger

  @moduletag :tier1

  alias Merlin.Effects
  alias Merlin.Effects.{Report, Tap}

  setup do
    Tap.clear()
    Merlin.Settle.finish()
    Application.put_env(:merlin, :dry_run, false)

    on_exit(fn ->
      Tap.clear()
      Merlin.Settle.finish()
      Application.delete_env(:merlin, :dry_run)
    end)

    :ok
  end

  # --- the tap itself -------------------------------------------------------

  describe "subscription" do
    test "nobody is subscribed by default" do
      assert Tap.subscribers() == []
    end

    test "subscribe and unsubscribe" do
      :ok = Tap.subscribe()
      assert self() in Tap.subscribers()

      :ok = Tap.unsubscribe()
      refute self() in Tap.subscribers()
    end

    test "subscribing twice does not double-deliver" do
      :ok = Tap.subscribe()
      :ok = Tap.subscribe()

      assert Tap.subscribers() == [self()]

      Tap.notify(:performed, {:log, :info, "x"}, nil)
      assert_receive {:merlin_effect, %Report{}}
      refute_receive {:merlin_effect, %Report{}}, 50
    end

    test "notify with no subscribers builds nothing and returns nil" do
      # The hot path. With nobody listening this must not allocate a report,
      # which is why it returns nil rather than a struct nobody asked for.
      assert Tap.notify(:performed, {:log, :info, "x"}, nil) == nil
    end

    test "every subscriber receives every report" do
      parent = self()
      other = spawn_link(fn -> relay(parent) end)

      :ok = Tap.subscribe()
      :ok = Tap.subscribe(other)

      Tap.notify(:dry_run, {:log, :info, "x"}, {:rule, :r})

      assert_receive {:merlin_effect, %Report{outcome: :dry_run}}
      assert_receive {:relayed, %Report{outcome: :dry_run}}
    end

    test "a subscriber on another node is never pruned by guessing" do
      # Process.alive?/1 raises on a remote pid rather than answering, so a
      # naive liveness check turns every effect into an ArgumentError the
      # moment a TUI attaches from another node -- which is the whole point of
      # the tap existing.
      #
      # Asserted by varying the node rather than the pid: a genuinely remote
      # pid cannot be fabricated (list_to_pid refuses a node this VM has never
      # seen) and standing up distribution has no business in a unit tier. The
      # branch is the same one either way.
      assert Tap.dead?(self(), :"somewhere@else") == false,
             "a pid on another node must be treated as alive, not probed"
    end

    test "a dead pid on this node is dead" do
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _}

      assert Tap.dead?(dead, node()) == true
      assert Tap.dead?(self(), node()) == false
    end

    test "a dead subscriber is pruned, and only when one is seen" do
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _}

      :ok = Tap.subscribe()
      :ok = Tap.subscribe(dead)
      assert length(Tap.subscribers()) == 2

      Tap.notify(:performed, {:log, :info, "x"}, nil)
      assert_receive {:merlin_effect, %Report{}}

      assert Tap.subscribers() == [self()],
             "a subscriber that has died must not be kept for ever"
    end
  end

  # --- outcomes -------------------------------------------------------------

  describe "the outcome of an effect" do
    setup do
      :ok = Tap.subscribe()
      :ok
    end

    test "a dispatch that works reports :performed" do
      Effects.perform([{:log, :info, "hello"}], rule: :r)
      assert_receive {:merlin_effect,
                      %Report{outcome: :performed, effect: {:log, :info, "hello"}}}
    end

    test "dry run reports :dry_run and does not dispatch" do
      Effects.perform([{:log, :info, "hello"}], rule: :r, dry_run: true)
      assert_receive {:merlin_effect, %Report{outcome: :dry_run}}
    end

    test "an effect held by the settle window reports how long is left" do
      Merlin.Settle.begin(:test, 5_000)

      # notify is outward alerting, so the window holds it. A :log would not
      # be held, which is the point of asserting against a suppressed effect.
      Effects.perform([{:notify, :log, "intruder"}], rule: :r)

      assert_receive {:merlin_effect, %Report{outcome: {:held, remaining}}}
      assert remaining > 0 and remaining <= 5_000
    end

    test "a dispatch that fails reports why" do
      Effects.perform([{:notify, :carrier_pigeon, "hello"}], rule: :r)

      assert_receive {:merlin_effect,
                      %Report{outcome: {:failed, {:unknown_channel, :carrier_pigeon}}}}
    end

    test "dry run wins over the settle window" do
      # Both branches would suppress; only one may be reported, and the daemon
      # being in dry run is the more fundamental fact about what happened.
      Merlin.Settle.begin(:test, 5_000)
      Effects.perform([{:notify, :log, "x"}], rule: :r, dry_run: true)

      assert_receive {:merlin_effect, %Report{outcome: :dry_run}}
    end

    test "each effect in a list is reported separately, in order" do
      Effects.perform([{:log, :info, "first"}, {:log, :info, "second"}], rule: :r)

      assert_receive {:merlin_effect, %Report{effect: {:log, :info, "first"}}}
      assert_receive {:merlin_effect, %Report{effect: {:log, :info, "second"}}}
    end

    test "a report carries both a monotonic and a wall stamp" do
      before_wall = System.system_time(:millisecond)
      Effects.perform([{:log, :info, "x"}], rule: :r)

      assert_receive {:merlin_effect, %Report{at: at, wall: wall}}

      # Monotonic for ordering and age, wall for display. Monotonic time is
      # routinely negative and means nothing to a human; wall time is unsafe
      # to subtract. Carrying one and deriving the other loses information.
      assert is_integer(at)
      assert wall >= before_wall
    end
  end

  # --- attribution ----------------------------------------------------------

  describe "who caused it" do
    setup do
      :ok = Tap.subscribe()
      :ok
    end

    test "a rule id becomes a {:rule, id} source" do
      Effects.perform([{:log, :info, "x"}], rule: :lamps_toggle)
      assert_receive {:merlin_effect, %Report{source: {:rule, :lamps_toggle}}}
    end

    test "an explicit source overrides the rule id" do
      Effects.perform([{:log, :info, "x"}], rule: :ignored, source: {:operator, "root@pts/0"})
      assert_receive {:merlin_effect, %Report{source: {:operator, "root@pts/0"}}}
    end

    test "the rendered suffix for a rule is unchanged" do
      # The soak runbook greps for " (rule_id)". Changing this shape would
      # silently break every documented grep in docs/soak.md.
      assert Effects.source_suffix({:rule, :lamps_toggle}) == " (lamps_toggle)"
    end

    test "an operator is rendered as an operator, not as a rule" do
      # Passing rule: :tui would have written a lie into the log -- there is no
      # rule called tui, and a reader six months later has no way to know that.
      assert Effects.source_suffix({:operator, "root@pts/0"}) == " (operator root@pts/0)"
    end

    test "no source renders nothing at all" do
      assert Effects.source_suffix(nil) == ""
    end
  end

  # --- the tap does not disturb what it observes ----------------------------

  describe "observation is not interference" do
    test "perform still returns the effects it was given" do
      effects = [{:log, :info, "a"}, {:log, :info, "b"}]
      assert Effects.perform(effects, rule: :r) == effects
    end

    test "the pre-filter test observer still fires, and still fires first" do
      # The observer and this tap answer different questions: the observer
      # reports what a rule DECIDED, before dry-run and settle are considered,
      # which is what lets a unit tier assert ordering without a broker. This
      # tap reports what BECAME of each effect. Neither is the other's
      # duplicate, and removing either would lose a distinct claim.
      Application.put_env(:merlin, :effects_observer, self())
      :ok = Tap.subscribe()
      on_exit(fn -> Application.delete_env(:merlin, :effects_observer) end)

      Effects.perform([{:log, :info, "x"}], rule: :r, dry_run: true)

      assert_receive {:effects, :r, [{:log, :info, "x"}]}
      assert_receive {:merlin_effect, %Report{outcome: :dry_run}}
    end
  end

  describe "a live effect says so, exactly once" do
    setup do
      # These assert on log lines, so the level must be low enough to emit them
      # and restored afterwards or every later test inherits the change.
      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)
      :ok
    end

    # {:notify, :log, _} and {:log, _, _} write their own line. A "[live]"
    # announcement beside it would make one event look like two, and in an
    # alerting path -- both vehicle rules and the intruder latch ship as
    # {:notify, :log, _} -- two lines read as two incidents.
    test "a notify-to-log effect is not announced twice" do
      log = capture_log(fn -> Effects.perform([{:notify, :log, "intruder"}], rule: :r) end)

      assert log =~ "intruder"
      refute log =~ "[live]",
             "a self-logging effect was announced by [live] as well as by itself"
    end

    test "a log effect is not announced twice" do
      log = capture_log(fn -> Effects.perform([{:log, :info, "hello"}], rule: :r) end)

      assert log =~ "hello"
      refute log =~ "[live]"
    end

    # The control. If [live] were never emitted for anything, the two tests
    # above would pass on an implementation that deleted the feature outright,
    # which is the failure mode they exist to prevent. A set_fact is not an
    # outward effect either, so this pins the boundary from the other side:
    # what is NOT announced is a decision, not an accident of the log level.
    test "an internal fact write is not announced as an outward effect" do
      log = capture_log(fn -> Effects.perform([{:set_fact, [:t, "x"], 1}], rule: :r) end)

      refute log =~ "[live]",
             "set_fact is internal bookkeeping and must not read as the house moving"
    end
  end

  defp relay(parent) do
    receive do
      {:merlin_effect, report} ->
        send(parent, {:relayed, report})
        relay(parent)
    end
  end
end
