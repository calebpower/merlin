defmodule Merlin.CodecTest do
  @moduledoc """
  Tier 1: payload decoding.

  The parity cases here are transcribed from `home_doors.py` and
  `livingroom_lamps.py`. The door codec in particular has a priority order and
  a truthiness rule that the Python inherited from the language rather than
  stating; both are asserted explicitly now.
  """

  use ExUnit.Case, async: true

  @moduletag :tier1

  alias Merlin.Codec

  describe "primitives" do
    test "raw passes bytes through" do
      assert Codec.decode("hello", :raw) == {:ok, "hello"}
      assert Codec.decode("", :raw) == {:ok, ""}
    end

    test "json" do
      assert Codec.decode(~s({"a":1}), :json) == {:ok, %{"a" => 1}}
      assert Codec.decode("not json", :json) == :error
      assert Codec.decode("", :json) == :error
    end

    test "integers and floats reject trailing junk" do
      assert Codec.decode("42", :integer) == {:ok, 42}
      assert Codec.decode(" 42 ", :integer) == {:ok, 42}
      assert Codec.decode("42abc", :integer) == :error
      assert Codec.decode("1.5", :float) == {:ok, 1.5}
      assert Codec.decode("abc", :float) == :error
    end
  end

  describe "enum" do
    test "maps a closed set" do
      spec = {:enum, %{"ON" => :on, "OFF" => :off}}
      assert Codec.decode("ON", spec) == {:ok, :on}
      assert Codec.decode("OFF", spec) == {:ok, :off}
    end

    test "refuses anything outside the map" do
      # A device inventing a new state must not quietly become a fact nobody
      # declared. The Python passed unknown strings straight through.
      spec = {:enum, %{"ON" => :on, "OFF" => :off}}
      assert Codec.decode("on", spec) == :error
      assert Codec.decode("TOGGLE", spec) == :error
      assert Codec.decode("", spec) == :error
    end
  end

  describe "truthy — the zigbee2mqtt contact convention" do
    test "contact: true means CLOSED" do
      # zigbee2mqtt reports magnet-together as contact: true.
      assert Codec.decode(true, {:truthy, :closed, :open}) == {:ok, :closed}
      assert Codec.decode(false, {:truthy, :closed, :open}) == {:ok, :open}
    end

    test "the truthiness rule is stated, not inherited" do
      refute Codec.truthy?(false)
      refute Codec.truthy?(nil)
      refute Codec.truthy?(0)
      refute Codec.truthy?("")
      refute Codec.truthy?([])
      assert Codec.truthy?(true)
      assert Codec.truthy?(1)
      assert Codec.truthy?("x")
    end
  end

  describe "dig — nested fields and alternatives" do
    test "pulls a nested path" do
      body = ~s({"print_stats":{"state":"printing"}})
      {:ok, decoded} = Codec.decode(body, :json)
      assert Codec.dig(decoded, ["print_stats", "state"], :raw) == {:ok, "printing"}
    end

    test "first matching alternative wins" do
      # klipper_monitor.py accepted state at either depth with an `or`.
      flat = %{"state" => "printing"}
      nested = %{"print_stats" => %{"state" => "complete"}}
      alts = [["state"], ["print_stats", "state"]]

      assert Codec.dig(flat, alts, :raw) == {:ok, "printing"}
      assert Codec.dig(nested, alts, :raw) == {:ok, "complete"}
    end

    test "no alternative matching is :error, not nil" do
      assert Codec.dig(%{"other" => 1}, [["state"], ["print_stats", "state"]], :raw) == :error
    end

    test "digging into a non-map is :error rather than a crash" do
      assert Codec.dig("a string", ["state"], :raw) == :error
      assert Codec.dig(nil, ["state"], :raw) == :error
    end

    test "an inner codec is applied to the dug value" do
      assert Codec.dig(%{"state" => "ON"}, ["state"], {:enum, %{"ON" => :on}}) == {:ok, :on}
    end

    test "an inner truthy codec applies to an already-decoded boolean" do
      assert Codec.dig(%{"contact" => true}, ["contact"], {:truthy, :closed, :open}) ==
               {:ok, :closed}
    end
  end

  describe "the door parity cases, end to end" do
    # Transcribed from home_doors.py's payload handling, in its priority order.
    defp door(payload) do
      {:ok, decoded} = Codec.decode(payload, :json)

      case Codec.dig(decoded, [["contact"]], {:truthy, :closed, :open}) do
        {:ok, v} -> v
        :error -> elem_or(Codec.dig(decoded, [["state"]], {:enum, %{"ON" => :open, "OFF" => :closed}}), :unknown)
      end
    end

    defp elem_or({:ok, v}, _), do: v
    defp elem_or(:error, default), do: default

    test "contact true is closed, false is open" do
      assert door(~s({"contact":true})) == :closed
      assert door(~s({"contact":false})) == :open
    end

    test "state ON is open, OFF is closed" do
      assert door(~s({"state":"ON"})) == :open
      assert door(~s({"state":"OFF"})) == :closed
    end

    test "contact wins over state when both are present" do
      assert door(~s({"contact":true,"state":"ON"})) == :closed
    end

    test "neither present yields unknown, not a wrong guess" do
      assert door(~s({"battery":90})) == :unknown
    end
  end
end
