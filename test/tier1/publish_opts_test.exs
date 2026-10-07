defmodule Merlin.PublishOptsTest do
  @moduledoc """
  Tier 1: a config-level publish may ask for `:retain` and `:qos`.

  `MQTT.Client.publish/3` has carried both since the transport was written, but
  nothing a house could write reached them: `Rule.compile_action/1` accepted only
  `{:publish, topic, payload}` and the resolver emitted `[]`. So every message
  merlin sent was unretained, which is an EDGE -- a subscriber that was not
  listening at that instant never learns the value, and one that reconnects gets
  nothing until the next change. For a derived aggregate published for something
  else to read, retention is what makes it a level instead.

  The options are checked at COMPILE time rather than at publish time, because a
  broker's answer to a bad option is to drop the message, and a publish that
  silently never arrives is the shape this project keeps paying for.
  """

  use ExUnit.Case, async: true

  @moduletag :tier1

  alias Merlin.{Effects, Rule}

  defp rule(action), do: Rule.compile(%{id: :r, on: [{:changes, [:a, :b]}], do: [action]})

  defp actions(action) do
    {:ok, compiled} = rule(action)
    compiled.actions
  end

  describe "compiling a publish with options" do
    test "the three-argument form still compiles and still means no options" do
      assert actions({:publish, "t/x", "payload"}) == [{:publish, "t/x", {:lit, "payload"}}]
    end

    test "retain and qos are carried through to the compiled action" do
      assert actions({:publish, "t/x", "payload", retain: true}) ==
               [{:publish, "t/x", {:lit, "payload"}, [retain: true]}]

      assert actions({:publish, "t/x", "payload", qos: 1, retain: true}) ==
               [{:publish, "t/x", {:lit, "payload"}, [qos: 1, retain: true]}]
    end

    # THE ARM THAT MATTERS. A silently ignored typo is a config that reads as
    # though it asked for retention and did not get it -- and the symptom appears
    # only at the far end, as a reader that sees nothing after a restart.
    test "a misspelled option is refused by name rather than ignored" do
      assert {:error, {_, {:unknown_publish_opts, [:retian]}}} =
               rule({:publish, "t/x", "p", retian: true})
    end

    test "a non-boolean retain and an out-of-range qos are both refused" do
      assert {:error, {_, {:bad_retain, "yes"}}} = rule({:publish, "t/x", "p", retain: "yes"})
      assert {:error, {_, {:bad_qos, 3}}} = rule({:publish, "t/x", "p", qos: 3})
    end

    test "options that are not a keyword list are refused" do
      assert {:error, {_, {:publish_opts_not_a_keyword_list, _}}} =
               rule({:publish, "t/x", "p", ["retain"]})
    end
  end

  describe "resolving to an effect" do
    defp env, do: %{read: fn _ -> :unknown end, trigger: %{}, locals: %{}, group: fn _ -> [] end}

    test "the options survive resolution, which is what reaches the transport" do
      assert Effects.resolve([{:publish, "t/x", {:lit, "p"}, [retain: true]}], env(), %{}) ==
               {:ok, [{:publish, "t/x", "p", [retain: true]}]}
    end

    test "and a publish with no options still resolves to the empty list" do
      assert Effects.resolve([{:publish, "t/x", {:lit, "p"}}], env(), %{}) ==
               {:ok, [{:publish, "t/x", "p", []}]}
    end
  end

  describe "the direct command path" do
    test "Control.resolve accepts options and still refuses a wildcard with them" do
      assert Merlin.Control.resolve({:publish, "t/x", "p", retain: true}) ==
               {:ok, [{:publish, "t/x", "p", [retain: true]}]}

      # A retained publish to a pattern would be worse than an unretained one:
      # a broker that accepts it leaves the bad message behind for every future
      # subscriber.
      assert Merlin.Control.resolve({:publish, "t/+/x", "p", retain: true}) ==
               {:error, {:wildcard_topic, "t/+/x"}}
    end
  end
end
