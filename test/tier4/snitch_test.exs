defmodule Merlin.HTTP.SnitchTest do
  @moduledoc """
  Tier 4: server contract.

  The question this tier answers that no cheaper one can: does the
  authorization surface behave correctly across **every** key state, and does
  it behave *identically* to the caller in all the failing ones.

  The matrix is key-state x request-shape, and the two halves assert opposite
  things:

    * exactly one combination has an effect, and it injects to the topic the
      key resolves to and no other; and
    * every other combination is indistinguishable from the outside -- same
      status, same body -- because `/snitch` must not be usable as an oracle
      for whether a key is live.

  It also asserts the thing that actually leaked: that a real request does not
  put the key in the log.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  import ExUnit.CaptureLog

  @moduletag :tier4

  alias Merlin.KeyStore

  @router Merlin.HTTP.PublicRouter
  @opts Merlin.HTTP.PublicRouter.init([])

  # A test double that reports what was injected back to the test process.
  defmodule EchoIngress do
    @behaviour Merlin.Ingress

    @impl true
    def inject(topic, payload, opts) do
      send(:snitch_test_observer, {:injected, topic, payload, opts})
      1
    end
  end

  setup do
    Process.register(self(), :snitch_test_observer)

    path =
      Path.join(
        System.tmp_dir!(),
        "merlin-snitch-#{System.unique_integer([:positive])}.db"
      )

    Application.put_env(:merlin, :ingress, EchoIngress)
    Application.put_env(:merlin, :db_path_override, path)
    prev_db = System.get_env("MERLIN_DB")
    System.put_env("MERLIN_DB", path)

    on_exit(fn ->
      Application.delete_env(:merlin, :ingress)
      if prev_db, do: System.put_env("MERLIN_DB", prev_db), else: System.delete_env("MERLIN_DB")
      File.rm(path)
      File.rm(path <> "-wal")
      File.rm(path <> "-shm")
    end)

    {:ok, key} =
      KeyStore.with_db(path, fn db ->
        {:ok, plaintext, _row} = KeyStore.mint(db, "http/mobile/ariia/state", label: "test")
        {:ok, plaintext}
      end)

    %{db: path, key: key}
  end

  defp post_snitch(body) when is_binary(body) do
    conn(:post, "/snitch", body)
    |> put_req_header("content-type", "application/json")
    |> @router.call(@opts)
  end

  defp post_snitch(body), do: post_snitch(Jason.encode!(body))

  describe "the one combination that works" do
    test "a valid key injects to the topic it resolves to", %{key: key} do
      conn = post_snitch(%{challenge: key, status: %{"gps_latitude" => 1.5}})

      assert conn.status == 200
      assert_receive {:injected, "http/mobile/ariia/state", payload, opts}

      assert Jason.decode!(payload) == %{"gps_latitude" => 1.5}
      assert {:http, id} = opts[:source]
      assert is_integer(id)
    end

    test "a string status passes through verbatim", %{key: key} do
      post_snitch(%{challenge: key, status: "raw text"})
      assert_receive {:injected, _topic, "raw text", _}
    end

    test "the key cannot choose its topic", %{key: key} do
      # There is no topic parameter, and supplying one changes nothing. The
      # capability is the key; this is the property worth preserving from the
      # Python and the reason a leaked key is not an account.
      post_snitch(%{challenge: key, status: "x", topic: "some/other/topic"})
      assert_receive {:injected, "http/mobile/ariia/state", _, _}
    end
  end

  describe "every rejected state is indistinguishable" do
    test "unknown key", %{} do
      conn = post_snitch(%{challenge: "not-a-real-key", status: "x"})
      assert conn.status == 200
      assert conn.resp_body == "OK"
      refute_receive {:injected, _, _, _}, 50
    end

    test "revoked key", %{db: db, key: key} do
      KeyStore.with_db(db, fn c -> KeyStore.delete(c, {:key, key}) end)

      conn = post_snitch(%{challenge: key, status: "x"})
      assert conn.status == 200
      refute_receive {:injected, _, _, _}, 50
    end

    test "expired key", %{db: db} do
      {:ok, expired} =
        KeyStore.with_db(db, fn c ->
          {:ok, plaintext, _} = KeyStore.mint(c, "http/expired", expires_in_days: -1)
          {:ok, plaintext}
        end)

      conn = post_snitch(%{challenge: expired, status: "x"})
      assert conn.status == 200
      refute_receive {:injected, _, _, _}, 50
    end

    test "empty challenge" do
      conn = post_snitch(%{challenge: "", status: "x"})
      assert conn.status == 200
      refute_receive {:injected, _, _, _}, 50
    end

    test "missing challenge" do
      conn = post_snitch(%{status: "x"})
      assert conn.status == 200
      refute_receive {:injected, _, _, _}, 50
    end

    test "null status is treated as no request", %{key: key} do
      # Preserved from api.py: `status is None` skipped the whole block.
      conn = post_snitch(%{challenge: key, status: nil})
      assert conn.status == 200
      refute_receive {:injected, _, _, _}, 50
    end

    test "missing status", %{key: key} do
      conn = post_snitch(%{challenge: key})
      assert conn.status == 200
      refute_receive {:injected, _, _, _}, 50
    end

    test "challenge of the wrong type", %{} do
      conn = post_snitch(%{challenge: 12_345, status: "x"})
      assert conn.status == 200
      refute_receive {:injected, _, _, _}, 50
    end

    test "malformed JSON" do
      conn = post_snitch("{not json")
      assert conn.status == 200
      refute_receive {:injected, _, _, _}, 50
    end

    test "empty body" do
      conn = post_snitch("")
      assert conn.status == 200
    end

    test "an oversized body is capped, not buffered, and still answers 200" do
      # 1 MiB against a 32 KiB cap. The response must be indistinguishable from
      # every other rejection, and the daemon must not have held the whole body
      # in memory to decide that.
      giant = Jason.encode!(%{challenge: String.duplicate("x", 1_000_000), status: "y"})
      conn = post_snitch(giant)

      assert conn.status == 200
      assert conn.resp_body == "OK"
      refute_receive {:injected, _, _, _}, 50
    end

    test "a valid key in an oversized body is still rejected", %{key: key} do
      # The cap must not be bypassable by putting something legitimate first.
      padded = Jason.encode!(%{challenge: key, status: String.duplicate("z", 1_000_000)})
      conn = post_snitch(padded)

      assert conn.status == 200
      refute_receive {:injected, _, _, _}, 50
    end

    test "every rejection has the identical response" do
      # The oracle property, asserted as a set rather than case by case.
      bodies = [
        Jason.encode!(%{challenge: "wrong", status: "x"}),
        Jason.encode!(%{challenge: "", status: "x"}),
        Jason.encode!(%{status: "x"}),
        Jason.encode!(%{challenge: "wrong"}),
        "{not json",
        "",
        Jason.encode!(%{challenge: String.duplicate("x", 100_000), status: "y"})
      ]

      responses =
        Enum.map(bodies, fn body ->
          conn = post_snitch(body)
          {conn.status, conn.resp_body}
        end)

      assert Enum.uniq(responses) == [{200, "OK"}],
             "rejections are distinguishable: #{inspect(Enum.uniq(responses))}"
    end
  end

  describe "the key does not reach the log" do
    test "a successful request logs nothing secret", %{key: key} do
      log = capture_log(fn -> post_snitch(%{challenge: key, status: "x"}) end)

      refute log =~ key,
             "the API key appeared in the log -- this is api.py:31 all over again"
    end

    test "a rejected request logs nothing secret" do
      secret = "super-secret-key-value"
      log = capture_log(fn -> post_snitch(%{challenge: secret, status: "x"}) end)

      refute log =~ secret
    end

    test "a raising handler logs nothing secret", %{key: key} do
      # The rescue path formats an exception, not the body. Asserted because
      # "we do not log the body" is easy to believe and easy to break.
      log = capture_log(fn -> post_snitch(%{challenge: key, status: %{"deep" => %{"a" => 1}}}) end)
      refute log =~ key
    end
  end

  describe "healthz" do
    test "reports status without requiring a key" do
      conn = conn(:get, "/healthz") |> @router.call(@opts)

      assert conn.status in [200, 503]
      body = Jason.decode!(conn.resp_body)
      assert Map.has_key?(body, "status")
      assert Map.has_key?(body, "dry_run")
    end
  end

  describe "unknown routes" do
    test "404, and nothing else is mounted on the public listener" do
      for path <- ["/facts.json", "/rules.json", "/admin", "/"] do
        conn = conn(:get, path) |> @router.call(@opts)

        assert conn.status == 404,
               "#{path} is reachable on the internet-facing listener"
      end
    end
  end

  describe "the operator is told why a request was rejected" do
    # The always-200 rule is about what the CLIENT learns. Collapsing every
    # failure into a silent :ok left the operator with a 200 and an empty log
    # for a wrong key, a missing field and malformed JSON alike -- which is
    # exactly the position a real deployment sat in for an afternoon.
    #
    # The reason is logged. The key never is.
    import ExUnit.CaptureLog

    # The test environment filters at :warning. These messages are :info --
    # correctly, since a rejected request is information rather than a fault,
    # and production runs at :info so they will appear there. Raising the
    # level here is the right way round: the code should not be logged louder
    # than it deserves to satisfy a test.
    setup do
      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)
      :ok
    end

    defp post_body(body) do
      capture_log(fn ->
        conn(:post, "/snitch", body) |> put_req_header("content-type", "application/json")
        |> Merlin.HTTP.PublicRouter.call([])
        Process.sleep(20)
      end)
    end

    test "malformed JSON says so" do
      assert post_body("{not json") =~ "not valid JSON"
    end

    test "a missing challenge names the keys that were present" do
      log = post_body(~s({"status":{"a":1}}))
      assert log =~ "no `challenge` field"
      assert log =~ "status"
    end

    test "a missing status says so" do
      assert post_body(~s({"challenge":"abcdefghijkl"})) =~ "no `status` field"
    end

    test "a null status is distinguished from a missing one" do
      assert post_body(~s({"challenge":"abcdefghijkl","status":null})) =~ "is null"
    end

    test "a non-string challenge names its type" do
      assert post_body(~s({"challenge":123,"status":{"a":1}})) =~ "not a string"
    end

    test "an unrecognised key is reported by PREFIX, never in full" do
      key = "abcdefghijklmnopqrstuvwxyz012345"
      log = post_body(~s({"challenge":"#{key}","status":{"a":1}}))

      assert log =~ "not recognised"
      assert log =~ "abcdefgh"

      refute log =~ key,
             "the full key was written to the log -- api.py:31 all over again"

      refute log =~ "ijklmnop",
             "more than the identifying prefix reached the log"
    end

    test "the reason mentions where to look" do
      log = post_body(~s({"challenge":"abcdefghijklmnop","status":{"a":1}}))
      assert log =~ "merlin-key list"
    end
  end

  describe "the key may travel in a header, with the body as the payload" do
    # The better shape, and the one that should have been original. A
    # credential in the body forces the body into merlin's envelope, so the
    # DEVICE has to be reconfigured to merlin -- and a device is usually the
    # thing you cannot change or test. With the key in a header the body is
    # whatever the device natively sends, injected verbatim.
    defp post_with(body, headers) do
      Enum.reduce(headers, conn(:post, "/snitch", body), fn {k, v}, c ->
        put_req_header(c, k, v)
      end)
      |> put_req_header("content-type", "application/json")
      |> @router.call(@opts)
    end

    test "x-api-key with a raw body injects the body verbatim", %{key: key} do
      body = ~s({"gps_latitude":51.4779,"gps_longitude":-0.0015,"batt_level":88})

      assert %{status: 200} = post_with(body, [{"x-api-key", key}])

      assert_receive {:injected, "http/mobile/ariia/state", payload, opts}
      assert payload == body, "the body was rewrapped rather than passed through"
      assert {:http, id} = opts[:source]
      assert is_integer(id)
    end

    test "authorization: Bearer works too", %{key: key} do
      body = ~s({"gps_latitude":51.5})
      assert %{status: 200} = post_with(body, [{"authorization", "Bearer " <> key}])
      assert_receive {:injected, "http/mobile/ariia/state", ^body, _}
    end

    test "a bad header key injects nothing and is reported by prefix" do
      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)

      bad = "not-a-real-key-at-all-0123456789"

      log =
        capture_log(fn ->
          assert %{status: 200} = post_with(~s({"gps_latitude":1.0}), [{"x-api-key", bad}])
        end)

      refute_receive {:injected, _, _, _}, 50
      assert log =~ "from the header is not"
      assert log =~ "not-a-re"
      refute log =~ bad, "the full key reached the log"
    end

    # The envelope must keep working: things already use it.
    test "the challenge/status envelope still works", %{key: key} do
      assert %{status: 200} =
               post_with(~s({"challenge":"#{key}","status":{"gps_latitude":51.4}}), [])

      assert_receive {:injected, "http/mobile/ariia/state", payload, _}
      assert Jason.decode!(payload) == %{"gps_latitude" => 51.4}
    end

    # An empty header must not count as a credential, or it silently bypasses
    # the envelope path and every such request is dropped with a confusing
    # reason.
    test "an empty x-api-key falls through to the envelope" do
      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)

      log =
        capture_log(fn ->
          post_with(~s({"gps_latitude":1.0}), [{"x-api-key", ""}])
        end)

      assert log =~ "no `challenge` field"
      refute_receive {:injected, _, _, _}, 50
    end

    # A header key must still be scoped to its own topic.
    test "a header key cannot write outside the topic it resolves to", %{key: key} do
      assert %{status: 200} = post_with(~s({"a":1}), [{"x-api-key", key}])
      assert_receive {:injected, topic, _, _}
      assert topic == "http/mobile/ariia/state"
    end
  end
end
