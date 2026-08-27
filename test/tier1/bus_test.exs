defmodule Merlin.BusTest do
  @moduledoc """
  Tier 1: prefix subscription and delivery.

  The claim under test is that a subscriber receives what it asked for and
  nothing else -- the property the Python's "every hook sees every message"
  dispatch could not offer -- and that it receives each change exactly once
  however many overlapping prefixes it registered.
  """

  use ExUnit.Case, async: true

  @moduletag :tier1

  alias Merlin.{Bus, Change, Event}

  # A unique ROOT per test, not a unique leaf.
  #
  # These tests are async against a process-global Registry, so a subscription
  # to a broad prefix in one test is live while another publishes beneath it.
  # The dedup test legitimately needs to subscribe at [:door] -- "every door"
  # -- and with a shared root that made every sibling test's "expected zero
  # subscribers" assertion race against it. Unique roots make the tests
  # genuinely independent instead of accidentally so.
  defp uniq, do: "bus-#{System.unique_integer([:positive])}"

  defp change(path), do: %Change{
    path: path,
    old: :old,
    new: :new,
    at: 0,
    source: nil,
    seq: 1,
    first?: false
  }

  defp event(path), do: %Event{path: path, payload: :p, at: 0, source: nil}

  # Bounded retry for a claim that is eventual rather than immediate.
  defp eventually(fun, attempts \\ 50) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(20)
        {:cont, false}
      end
    end)
  end

  describe "prefix matching" do
    test "an exact subscription receives its own path" do
      root = uniq()
      p = [root, "contact"]
      Bus.subscribe(p)

      assert 1 = Bus.publish(change(p))
      assert_receive {:merlin, %Change{path: ^p}}
    end

    test "a shorter prefix receives everything beneath it" do
      root = uniq()
      Bus.subscribe([root])

      assert 1 = Bus.publish(change([root, "contact"]))
      assert_receive {:merlin, %Change{}}

      assert 1 = Bus.publish(change([root, "battery"]))
      assert_receive {:merlin, %Change{}}
    end

    test "the empty prefix receives everything" do
      Bus.subscribe([])
      assert Bus.publish(change([uniq(), "anything"])) >= 1
      assert_receive {:merlin, %Change{}}
    end

    test "a sibling prefix receives nothing" do
      root = uniq()
      Bus.subscribe([root, "contact"])

      assert 0 = Bus.publish(change([root, "battery"]))
      refute_receive {:merlin, %Change{}}, 50
    end

    test "a longer prefix does not receive a shorter path" do
      root = uniq()
      Bus.subscribe([root, "contact", "deep"])

      assert 0 = Bus.publish(change([root, "contact"]))
      refute_receive {:merlin, %Change{}}, 50
    end
  end

  describe "deduplication" do
    test "overlapping subscriptions deliver exactly one message" do
      # A rule watching both [:door] and [:door, "office"] must act once on a
      # change, not twice. Without the dedupe in deliver/3 this is a
      # double-actuation bug that only shows up when someone adds a second,
      # broader subscription to an existing rule.
      root = uniq()
      Bus.subscribe([root])
      Bus.subscribe([root, "office"])
      Bus.subscribe([root, "office", "contact"])

      assert 1 = Bus.publish(change([root, "office", "contact"]))

      assert_receive {:merlin, %Change{}}
      refute_receive {:merlin, %Change{}}, 50
    end
  end

  describe "facts and events are separate namespaces" do
    test "a fact subscriber does not receive events on the same path" do
      root = uniq()
      p = [root, "pressed"]
      Bus.subscribe(p)

      assert 0 = Bus.emit(event(p))
      refute_receive {:merlin, %Event{}}, 50
    end

    test "an event subscriber does not receive changes on the same path" do
      root = uniq()
      p = [root, "pressed"]
      Bus.subscribe_events(p)

      assert 0 = Bus.publish(change(p))
      refute_receive {:merlin, %Change{}}, 50
    end
  end

  describe "unsubscribe" do
    test "stops delivery" do
      root = uniq()
      p = [root, "contact"]
      Bus.subscribe(p)
      assert 1 = Bus.publish(change(p))
      assert_receive {:merlin, %Change{}}

      Bus.unsubscribe(p)
      assert 0 = Bus.publish(change(p))
      refute_receive {:merlin, %Change{}}, 50
    end

    test "a dead subscriber is dropped automatically" do
      # Registry unregisters on process death. The Python callback list could
      # not: a dead hook stayed subscribed for the life of the daemon.
      root = uniq()
      p = [root, "contact"]
      test_pid = self()

      {:ok, sub} =
        Task.start(fn ->
          Bus.subscribe(p)
          send(test_pid, :subscribed)
          receive do: (:stop -> :ok)
        end)

      assert_receive :subscribed
      assert 1 = Bus.publish(change(p))

      ref = Process.monitor(sub)
      send(sub, :stop)
      assert_receive {:DOWN, ^ref, :process, ^sub, _}

      # Registry cleans up asynchronously, so a DOWN message does not mean the
      # entry is already gone. The claim is that it is dropped *eventually*,
      # without anyone having to unsubscribe -- which the Python's plain
      # callback list could never do at all. Assert that, not an immediate
      # guarantee Registry never made.
      assert eventually(fn -> Bus.publish(change(p)) == 0 end),
             "a dead subscriber was still receiving after 1s"
    end
  end
end
