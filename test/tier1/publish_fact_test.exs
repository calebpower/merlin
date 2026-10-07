defmodule Merlin.PublishFactTest do
  @moduledoc """
  Tier 1: publishing a FACT, with the two times that make it a level.

  A `{:publish, _, _, _}` payload is a compiled value, and a value cannot reach
  `observed_at` or `changed_at` -- an expression cannot read them at all. So
  "say what this fact is, when it was last confirmed, and when it last changed"
  had no spelling in a config, which is what `{:publish_fact, topic, path}` adds.

  The times are the whole point, and they go out as AGES rather than timestamps.
  `Merlin.Fact` keeps them MONOTONIC so an NTP step cannot make a fact look like
  it arrived from the future; a derived absolute re-reads the wall clock per
  publication and therefore jitters, which would show a reader edges that never
  happened. An age only grows while a value holds, and a drop IS the edge.
  """

  use ExUnit.Case, async: true

  @moduletag :tier1

  alias Merlin.{Effects, Rule, World}

  defp path(suffix), do: [:test, "#{System.unique_integer([:positive])}", suffix]

  defp rule(action), do: Rule.compile(%{id: :r, on: [{:changes, [:a, :b]}], do: [action]})

  defp actions(action) do
    {:ok, compiled} = rule(action)
    compiled.actions
  end

  defp payload(p), do: Jason.decode!(Effects.fact_payload(p))

  describe "compiling the action" do
    test "the short form means no options, and options are carried when given" do
      assert actions({:publish_fact, "t/x", [:a, :b]}) == [{:publish_fact, "t/x", [:a, :b], []}]

      assert actions({:publish_fact, "t/x", [:a, :b], retain: true}) ==
               [{:publish_fact, "t/x", [:a, :b], [retain: true]}]
    end

    test "options are validated the same way a plain publish's are" do
      assert {:error, {_, {:unknown_publish_opts, [:retian]}}} =
               rule({:publish_fact, "t/x", [:a, :b], retian: true})
    end

    test "an empty path is refused rather than published as nothing" do
      assert {:error, {_, {:bad_action, _}}} = rule({:publish_fact, "t/x", []})
    end
  end

  describe "the payload" do
    test "carries the value, a publication stamp, and both ages" do
      p = path(:level)
      World.put(p, :active)

      body = payload(p)

      assert body["value"] == "active"
      assert {:ok, _, _} = DateTime.from_iso8601(body["at"])
      assert is_integer(body["observed_ago_ms"]) and body["observed_ago_ms"] >= 0
      assert is_integer(body["changed_ago_ms"]) and body["changed_ago_ms"] >= 0
      # Observed no earlier than it changed, so its age is the smaller one.
      assert body["observed_ago_ms"] <= body["changed_ago_ms"]
    end

    # THE EDGE DETECTOR, AND WHY THIS IS AN AGE AND NOT A TIMESTAMP. A reader
    # spots a change by `changed_ago_ms` DROPPING. While the value holds it only
    # grows -- which a derived absolute does not guarantee: the first version of
    # this published `since`, and two messages about an unchanged fact disagreed
    # by 0.4 ms, because each re-derived the absolute from a separately read
    # wall clock. That is a phantom edge, and this test is the one that found it.
    test "re-observing the same value resets the observed age and only grows the changed age" do
      p = path(:level)
      World.put(p, :quiet)
      first = payload(p)
      Process.sleep(10)
      World.put(p, :quiet)
      second = payload(p)

      assert second["changed_ago_ms"] >= first["changed_ago_ms"] + 5
      assert second["observed_ago_ms"] <= first["changed_ago_ms"] + 5
    end

    test "a real change resets the changed age, which is what a reader watches for" do
      p = path(:level)
      World.put(p, :quiet)
      Process.sleep(10)
      before = payload(p)
      World.put(p, :active)
      after_change = payload(p)

      assert before["changed_ago_ms"] >= 10
      assert after_change["changed_ago_ms"] < before["changed_ago_ms"]
      assert after_change["value"] == "active"
    end

    test "an atom goes out as its own name and a boolean stays a boolean" do
      a = path(:atom)
      World.put(a, :active)
      assert payload(a)["value"] == "active"

      b = path(:bool)
      World.put(b, true)
      assert payload(b)["value"] == true
    end

    # THE THREE CASES A READER MUST NOT BE ABLE TO TELL APART, because none of
    # them is an answer: stale, absent, and genuinely unknown. And the times go
    # null rather than being reported against a value that is not there -- a
    # stale fact has no honest "how long since it changed", which is the rule
    # `unchanged_for?` already follows.
    test "a stale fact publishes unknown with no times" do
      p = path(:level)
      World.put(p, :active, stale_after: 1)
      Process.sleep(10)

      body = payload(p)
      assert body["value"] == "unknown"
      assert body["observed_ago_ms"] == nil
      assert body["changed_ago_ms"] == nil
    end

    test "a fact that has never arrived publishes unknown with no ages" do
      body = payload(path(:never))
      assert body["value"] == "unknown"
      assert body["observed_ago_ms"] == nil
      assert body["changed_ago_ms"] == nil
    end

    test "an :unknown value publishes unknown rather than the word as a value" do
      p = path(:level)
      World.put(p, :unknown)
      assert payload(p)["value"] == "unknown"
      assert payload(p)["changed_ago_ms"] == nil
    end

    # `at` is what makes a RETAINED message honest: the broker may replay it to
    # a subscriber hours later, and without the message's own stamp there is no
    # way to tell a fresh level from one held since yesterday.
    test "`at` is present even when there is nothing else to say" do
      assert {:ok, _, _} = DateTime.from_iso8601(payload(path(:never))["at"])
    end
  end

  describe "describe/1" do
    test "names the fact and the topic, for the effect log" do
      assert Effects.describe({:publish_fact, "merlin/home/presence", [:home, :presence], []}) ==
               "publish fact home.presence -> merlin/home/presence"
    end
  end
end
