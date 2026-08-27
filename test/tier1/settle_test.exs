defmodule Merlin.SettleTest do
  @moduledoc """
  Tier 1: the settle window's policy.

  Asserted as a policy function rather than by watching a daemon publish or not
  publish. "Which effects does a settle window hold back" is a decision, and a
  decision that can only be observed through a broker is one nobody can read.
  """

  use ExUnit.Case, async: false

  @moduletag :tier1

  alias Merlin.Settle

  setup do
    Settle.finish()
    on_exit(&Settle.finish/0)
    :ok
  end

  describe "what the window holds back" do
    # Outward effects. These are what reach the house and the phone.
    test "publishing is held" do
      assert Settle.suppresses?({:publish, "home/x/set", "ON", []})
    end

    test "commanding a group is held" do
      assert Settle.suppresses?({:set_group, :living_room_lamps, :on})
    end

    # The one that wakes you.
    test "notifying is held" do
      assert Settle.suppresses?({:notify, :discord, "unexpected activity at home"})
    end

    # Facts are the point of the window, not its casualty. A settle period that
    # discarded observations would leave the daemon ignorant when it ended,
    # which is worse than the problem it solves.
    test "writing a fact is NOT held -- learning is why the window exists" do
      refute Settle.suppresses?({:set_fact, [:a, :b], 1})
    end

    test "logging is NOT held -- it is how you see what the window absorbed" do
      refute Settle.suppresses?({:log, :info, "a door opened"})
    end

    # An effect type added later is held by default. The failure modes are not
    # symmetric: holding a new effect during the first fifteen seconds is a
    # delay, and letting an unreviewed one through is the 3am phone call.
    test "an unrecognised effect is held by default" do
      assert Settle.suppresses?({:some_future_effect, :arg})
    end
  end

  describe "the window itself" do
    # This is not a trivial base case. `System.monotonic_time/1` has an
    # arbitrary origin and is routinely NEGATIVE -- hours below zero on a
    # freshly booted machine. An implementation using 0 as the "no window"
    # sentinel computes `0 - (-3_000_000)` and reports itself as settling for
    # the next fifty minutes, suppressing every publish, group command and
    # notification, on precisely the machines that had just restarted.
    #
    # It passes on a developer machine that has been up long enough for the
    # clock to cross zero, which is what makes it worth asserting rather than
    # assuming.
    test "closed by default, whatever the sign of the monotonic clock" do
      refute Settle.settling?()
      assert Settle.remaining_ms() == 0
    end

    test "closed after finish, whatever the sign of the monotonic clock" do
      Settle.begin("test", 10_000)
      Settle.finish()

      refute Settle.settling?()
      assert Settle.remaining_ms() == 0
    end

    test "begin opens it" do
      Settle.begin("test", 10_000)
      assert Settle.settling?()
      assert Settle.remaining_ms() > 9_000
    end

    test "finish closes it" do
      Settle.begin("test", 10_000)
      Settle.finish()
      refute Settle.settling?()
    end

    test "a zero-length window never opens" do
      Settle.begin("test", 0)
      refute Settle.settling?()
    end

    # A reconnect during an open window must not shorten it. The second
    # retained burst is as much of a problem as the first, and the natural
    # implementation -- overwrite the deadline -- gets this backwards when the
    # new window is shorter than what remains.
    test "a second begin extends rather than shortens" do
      Settle.begin("first", 30_000)
      before = Settle.remaining_ms()

      Settle.begin("second, shorter", 1_000)

      assert Settle.remaining_ms() >= before - 100,
             "a shorter window truncated a longer one that was still open"
    end

    test "a longer second window does extend it" do
      Settle.begin("first", 1_000)
      Settle.begin("second, longer", 30_000)
      assert Settle.remaining_ms() > 20_000
    end
  end

  describe "configuration" do
    test "there is a default" do
      assert Settle.default_ms() > 0
    end

    test "the environment overrides it" do
      System.put_env("MERLIN_SETTLE_MS", "1234")
      on_exit(fn -> System.delete_env("MERLIN_SETTLE_MS") end)
      assert Settle.configured_ms() == 1234
    end

    # Being able to switch it off matters for tier 6, which must drive the
    # house immediately, and for anyone diagnosing a rule that will not fire.
    test "it can be switched off entirely" do
      System.put_env("MERLIN_SETTLE_MS", "0")
      on_exit(fn -> System.delete_env("MERLIN_SETTLE_MS") end)

      assert Settle.configured_ms() == 0
      Settle.begin("off", Settle.configured_ms())
      refute Settle.settling?()
    end
  end
end
