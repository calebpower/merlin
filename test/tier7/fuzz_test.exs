defmodule Merlin.FuzzTest do
  @moduledoc """
  Tier 7: seeded fuzzing.

  The methodology rates this highest defect-per-line, and aims it at the seams
  that actually broke. For merlin those are unambiguous: `/snitch` is the one
  endpoint reachable from the internet, and payload decoding is where a device
  firmware update lands.

  ## The oracle

  Not "the right answer" -- fuzzed input has no right answer. What must hold,
  whatever arrives:

    * the process does not crash;
    * `/snitch` answers 200 `OK` and nothing else, so no input class becomes
      distinguishable and the endpoint stays useless as a key oracle;
    * **nothing is ever injected without a valid key** -- the property that
      actually matters, and the one a crash-only oracle would miss entirely;
    * decoding either succeeds or returns `:error`, never raises.

  ## Determinism

  The seed is taken from `MERLIN_SEED`, printed by the harness into
  `out/seed.txt`, and replayed with `MERLIN_SEED=<n> reaper test`. A fuzz
  failure nobody can reproduce is an anecdote.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  @moduletag :tier7

  alias Merlin.{Codec, Expr, KeyStore}

  @router Merlin.HTTP.PublicRouter
  @opts Merlin.HTTP.PublicRouter.init([])

  defmodule NoIngress do
    @behaviour Merlin.Ingress

    @impl true
    def inject(topic, payload, opts) do
      send(:fuzz_observer, {:injected, topic, payload, opts})
      1
    end
  end

  setup_all do
    seed =
      case System.get_env("MERLIN_SEED") do
        nil -> :erlang.unique_integer([:positive])
        s -> String.to_integer(s)
      end

    IO.puts("\n  tier 7 seed: #{seed}  (MERLIN_SEED=#{seed} to replay)")
    :rand.seed(:exsss, {seed, seed, seed})
    %{seed: seed}
  end

  setup do
    Process.register(self(), :fuzz_observer)
    path = Path.join(System.tmp_dir!(), "merlin-fuzz-#{System.unique_integer([:positive])}.db")

    Application.put_env(:merlin, :ingress, NoIngress)
    prev = System.get_env("MERLIN_DB")
    System.put_env("MERLIN_DB", path)

    on_exit(fn ->
      Application.delete_env(:merlin, :ingress)
      if prev, do: System.put_env("MERLIN_DB", prev), else: System.delete_env("MERLIN_DB")
      for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix)
    end)

    {:ok, key} =
      KeyStore.with_db(path, fn db ->
        {:ok, plaintext, _} = KeyStore.mint(db, "http/fuzz/target")
        {:ok, plaintext}
      end)

    %{key: key}
  end

  # --- generators -----------------------------------------------------------

  defp rand_binary(max) do
    len = :rand.uniform(max)
    :crypto.strong_rand_bytes(len)
  end

  # One flat alphabet. The previous version picked from a list of ranges and
  # then tried to flatten with an is_list/1 guard -- but a Range is a struct,
  # not a list, so ranges survived into List.to_string/1 and it raised. The
  # generator was broken, not the code under test, which is its own small
  # lesson about instruments.
  @alphabet Enum.to_list(?a..?z) ++
              Enum.to_list(?0..?9) ++
              [?{, ?}, ?[, ?], ?", ?:, ?,, ?\\, ?/, ?., ?-, ?\s, ?\n]

  defp rand_utf8(max) do
    len = :rand.uniform(max)
    1..len |> Enum.map(fn _ -> Enum.random(@alphabet) end) |> List.to_string()
  end

  # A corpus shared with tiers 4 and 6: the shapes that have historically
  # broken this system or its predecessor.
  defp hostile_bodies(key) do
    [
      "",
      "{",
      "null",
      "[]",
      "[1,2,3]",
      "\"just a string\"",
      "{\"challenge\":null,\"status\":null}",
      "{\"challenge\":[],\"status\":{}}",
      "{\"challenge\":\"#{key}\"}",
      "{\"status\":\"orphan\"}",
      "{\"challenge\":\"#{key}\",\"status\":\"\"}",
      "{\"challenge\":\"#{key}\",\"status\":0}",
      "{\"challenge\":\"#{key}\",\"status\":false}",
      # Deep nesting: a decoder that recurses without a bound would go here.
      "{\"challenge\":\"#{key}\",\"status\":#{String.duplicate("[", 200)}1#{String.duplicate("]", 200)}}",
      # Invalid UTF-8 inside an otherwise valid envelope.
      <<"{\"challenge\":\"", 0xC3, 0x28, "\",\"status\":\"x\"}">>,
      # A key that is almost right.
      "{\"challenge\":\"#{String.slice(key, 0..-2//1)}\",\"status\":\"x\"}"
    ]
  end

  defp post(body) do
    conn(:post, "/snitch", body)
    |> put_req_header("content-type", "application/json")
    |> @router.call(@opts)
  end

  # --- the fuzz -------------------------------------------------------------

  describe "POST /snitch" do
    test "the hostile corpus never breaks the oracle", %{key: key} do
      for body <- hostile_bodies(key) do
        conn = post(body)

        assert conn.status == 200, "body #{inspect(binary_slice(body, 0, 40))} gave #{conn.status}"
        assert conn.resp_body == "OK"
      end
    end

    test "random bytes never break the oracle" do
      for _ <- 1..400 do
        body = rand_binary(600)
        conn = post(body)

        assert conn.status == 200
        assert conn.resp_body == "OK"
      end
    end

    test "random text never breaks the oracle" do
      for _ <- 1..400 do
        conn = post(rand_utf8(400))
        assert conn.status == 200
      end
    end

    test "nothing is ever injected without a valid key" do
      # The oracle that matters. A crash-only fuzz would pass while the
      # endpoint quietly accepted garbage as authorisation.
      for _ <- 1..500 do
        post(rand_binary(300))
        post(rand_utf8(200))
      end

      for body <- hostile_bodies("wrong-key-entirely"), do: post(body)

      refute_receive {:injected, _, _, _}, 100
    end

    test "a valid key still works after the storm", %{key: key} do
      # Fuzzing must not leave the endpoint wedged -- the "server is still
      # alive" half of the oracle, asserted rather than assumed.
      for _ <- 1..200, do: post(rand_binary(200))

      post(Jason.encode!(%{challenge: key, status: "still here"}))
      assert_receive {:injected, "http/fuzz/target", "still here", _}
    end
  end

  describe "codecs" do
    test "decoding never raises, whatever the bytes" do
      specs = [
        :raw,
        :json,
        :integer,
        :float,
        {:enum, %{"ON" => :on, "OFF" => :off}},
        {:truthy, :closed, :open},
        {:json_path, ["a", "b"], :raw}
      ]

      for _ <- 1..400 do
        payload = if :rand.uniform(2) == 1, do: rand_binary(200), else: rand_utf8(200)

        for spec <- specs do
          case Codec.decode(payload, spec) do
            {:ok, _} -> :ok
            :error -> :ok
          end
        end
      end
    end

    test "dig never raises on arbitrary decoded shapes" do
      shapes = [%{}, %{"a" => %{"b" => 1}}, [], [1, 2], "string", 42, nil, true]

      for shape <- shapes, path <- [["a"], ["a", "b"], ["missing"], []] do
        assert Codec.dig(shape, path, :raw) in [:error] or
                 match?({:ok, _}, Codec.dig(shape, path, :raw))
      end
    end
  end

  describe "the expression compiler" do
    test "never raises on arbitrary source, only refuses" do
      # compile/1 must be total: it is fed rule data, and a raise at boot on a
      # typo'd guard would take the daemon down rather than reporting the typo.
      for _ <- 1..400 do
        source = rand_utf8(80)

        case Expr.compile(source) do
          {:ok, _} -> :ok
          {:error, _} -> :ok
        end
      end
    end

    test "a compiled expression never raises on evaluation" do
      sources = [
        "a.b == :x",
        "a.b + 1",
        "a.b / c.d",
        "a.b > c.d",
        "if(a.b, c.d, e.f)",
        "all_eq?(:g, :on)",
        "distance(a.b, c.d)",
        "to_s(a.b)"
      ]

      values = [:unknown, nil, 0, 1, -1, "s", :atom, [], {1, 2}, {0.0, 0.0}, 1.5]

      for source <- sources, _ <- 1..40 do
        {:ok, expr} = Expr.compile(source)
        env = %{read: fn _ -> Enum.random(values) end, group: fn _ -> [] end}

        result = Expr.eval(expr, env)
        assert Expr.truthy?(result) in [true, false]
      end
    end
  end

  # --- the operator's own input seams ---------------------------------------
  #
  # Bytes from a terminal are not a trusted stream either -- a paste, a mouse
  # report, a sequence mangled over a slow link -- and a fact value reaching a
  # view came from an MQTT payload, which is the same untrusted source the
  # tests above already point at.
  #
  # Written with this file's own seeded PRNG rather than stream_data, so the
  # tier keeps ONE generator and one replay mechanism. Two would mean two seeds
  # to quote in a bug report and two things to keep in step.

  describe "the terminal seams" do
    test "key decoding never crashes, loops, or hoards its carry" do
      # The carry is the thing to watch: a decoder that keeps what it cannot
      # yet read must still make progress, or a fuzzed stream grows it without
      # bound. Nothing legitimately pends beyond three bytes of a part-arrived
      # character or an unfinished escape sequence.
      for _ <- 1..300 do
        bytes = rand_binary(400)
        {keys, carry} = Merlin.TUI.Keys.decode(bytes)

        assert is_list(keys)

        assert byte_size(carry) < 4 or String.starts_with?(carry, "\e"),
               "carry grew to #{byte_size(carry)} bytes"
      end
    end

    test "the command line never actuates by accident" do
      # Only three verbs reach the house. Anything else must be a view action,
      # an expression, or a refusal -- never something that commands a device.
      for _ <- 1..300 do
        line = rand_utf8(80)

        case Merlin.TUI.Command.parse(line) do
          {:control, _} ->
            assert String.starts_with?(String.trim(line), ["set", "publish", "fact"]),
                   "#{inspect(line)} became a control command"

          _ ->
            :ok
        end
      end
    end

    test "a hostile fact value cannot escape the grid" do
      # The same defect class as the ingest fuzzing above, one layer out: a
      # tampered device publishing an escape sequence must not be able to
      # repaint the operator's screen.
      for _ <- 1..200 do
        value = if :rand.uniform(2) == 1, do: rand_binary(60), else: rand_utf8(60)
        w = 20 + :rand.uniform(80)
        h = 3 + :rand.uniform(10)

        scene = %Merlin.TUI.Scene{
          facts: [
            %Merlin.Fact{
              path: [:fuzz, rand_utf8(20)],
              value: value,
              changed_at: 0,
              observed_at: 0,
              source: nil,
              seq: 1,
              stale_after: nil
            }
          ],
          now: 1_000
        }

        buffer = Merlin.TUI.View.Facts.render(scene, %{}, {w, h})
        text = Merlin.TUI.Buffer.to_text(buffer)

        assert buffer.w == w and buffer.h == h
        refute text =~ "\e"

        for line <- String.split(text, "\n") do
          assert String.length(line) == w,
                 "a row was #{String.length(line)} of #{w} columns"
        end
      end
    end
  end
end
