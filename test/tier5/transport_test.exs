defmodule Merlin.TransportTest do
  @moduledoc """
  Tier 5: the daemon against fakes, with deliberate transport error injection.

  The question this tier answers that no cheaper one can: what happens on the
  **failure paths**. A home network drops, a vendor 500s, DNS disappears for
  thirty seconds, a token is revoked early. None of that is exceptional and
  all of it is untestable against a real endpoint, because you cannot ask a
  vendor to fail on demand.

  Injection belongs here rather than on the live tier: tier 6 runs a real
  broker and a real release, where a deliberate fault would be
  indistinguishable from a genuine one.

  Two of the three bugs this milestone fixes are only observable here:

    * **bug 3** -- proactive token refresh. Against a real API you would have
      to wait an hour to find out it never happens.
    * **bug 4** -- Discord answering 204. Against the real Discord every send
      succeeds and the spurious error line looks like noise.
  """

  use ExUnit.Case, async: false

  @moduletag :tier5

  alias Merlin.{Notify, Secrets, Source, World}

  setup do
    Secrets.put(%{
      discord_webhook: "https://discord.example/webhook/abc",
      hapn_auth: "https://hapn.example/token",
      hapn_device: "https://hapn.example/device",
      hapn_id: "client-id",
      hapn_secret: "client-secret"
    })

    on_exit(fn -> Secrets.put(%{}) end)
    :ok
  end

  defp stub(name, fun) do
    Req.Test.stub(name, fun)
    [plug: {Req.Test, name}]
  end

  defp uniq, do: System.unique_integer([:positive])

  # --- Discord: bug 4 -------------------------------------------------------

  describe "the Discord notifier" do
    test "treats 204 as success — bug 4" do
      # Discord answers 204 No Content. alerts.py demanded exactly 200, so
      # every successful alert it ever sent also logged an error.
      opts = stub(:discord_204, fn conn -> Plug.Conn.send_resp(conn, 204, "") end)
      assert Notify.Discord.send("hello", req_options: opts) == :ok
    end

    test "treats 200 as success too" do
      opts = stub(:discord_200, fn conn -> Plug.Conn.send_resp(conn, 200, "{}") end)
      assert Notify.Discord.send("hello", req_options: opts) == :ok
    end

    test "logs nothing at error level on a successful send" do
      # The actual harm of bug 4: a log where success looks like failure
      # trains you to ignore the error lines.
      opts = stub(:discord_quiet, fn conn -> Plug.Conn.send_resp(conn, 204, "") end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Notify.Discord.send("hello", req_options: opts) == :ok
        end)

      refute log =~ "[error]"
      refute log =~ "[warning]"
    end

    test "sends the message as the content field" do
      test_pid = self()

      opts =
        stub(:discord_body, fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:body, Jason.decode!(body)})
          Plug.Conn.send_resp(conn, 204, "")
        end)

      Notify.Discord.send("the car has gone", req_options: opts)
      assert_receive {:body, %{"content" => "the car has gone"}}
    end

    test "retries a 429 and succeeds if the next attempt works" do
      counter = :counters.new(1, [])

      opts =
        stub(:discord_429, fn conn ->
          :counters.add(counter, 1, 1)

          if :counters.get(counter, 1) == 1 do
            Plug.Conn.send_resp(conn, 429, "slow down")
          else
            Plug.Conn.send_resp(conn, 204, "")
          end
        end)

      assert Notify.Discord.send("hello", req_options: opts) == :ok
      assert :counters.get(counter, 1) == 2
    end

    test "does NOT retry a 404 — a deleted webhook cannot be retried into existence" do
      counter = :counters.new(1, [])

      opts =
        stub(:discord_404, fn conn ->
          :counters.add(counter, 1, 1)
          Plug.Conn.send_resp(conn, 404, "")
        end)

      assert {:error, :webhook_deleted} = Notify.Discord.send("hello", req_options: opts)

      assert :counters.get(counter, 1) == 1,
             "a permanently dead webhook was retried #{:counters.get(counter, 1)} times"
    end

    test "gives up after a bounded number of attempts on repeated 5xx" do
      counter = :counters.new(1, [])

      opts =
        stub(:discord_500, fn conn ->
          :counters.add(counter, 1, 1)
          Plug.Conn.send_resp(conn, 500, "")
        end)

      assert {:error, _} = Notify.Discord.send("hello", req_options: opts)

      assert :counters.get(counter, 1) == Notify.Discord.max_attempts(),
             "retries are unbounded, or fewer than declared"
    end

    test "a transport error is retried and then reported, never raised" do
      opts =
        stub(:discord_transport, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, {:transport, _}} = Notify.Discord.send("hello", req_options: opts)
    end

    test "a missing webhook secret is an error, not a crash" do
      Secrets.put(%{})
      assert {:error, {:missing_secret, :discord_webhook}} = Notify.Discord.send("hello")
    end
  end

  # --- the poller: bug 3 ----------------------------------------------------

  describe "the HTTP poller's token lifecycle" do
    defp poller_spec(id, opts) do
      %{
        id: id,
        every: {1, :hour},
        auth: [
          url: {:secret, :hapn_auth},
          client_id: {:secret, :hapn_id},
          client_secret: {:secret, :hapn_secret}
        ],
        request: [url: {:secret, :hapn_device}],
        root: "result",
        facts: [%{path: [:test_poll, id, :speed], from: ["speed"]}],
        req_options: opts
      }
    end

    defp start_poller(id, opts) do
      {:ok, pid} = Source.HttpPoll.start_link(poller_spec(id, opts))
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
      pid
    end

    # THE REGRESSION. `params: %{"key" => secret}` is how a weather API is
    # configured, and the resolver used to walk only the top level of the
    # keyword list -- so the map value passed through untouched and Req was
    # handed a tuple to URL-encode. It raised, the supervisor restarted the
    # poller, it raised again about once a second, and when restart intensity
    # ran out the ENTIRE application shut down. The printer power cycle that
    # was running at the time never completed.
    #
    # Boot validation passed throughout, because `Secrets.referenced/1` walks
    # deeply and found the secret perfectly well.
    test "a secret nested in request params is resolved before the request" do
      test_pid = self()
      id = :"poll_#{uniq()}"

      opts =
        stub(:nested_params, fn conn ->
          conn = Plug.Conn.fetch_query_params(conn)
          send(test_pid, {:query, conn.query_params})
          Req.Test.json(conn, %{"temp" => 71})
        end)

      spec = %{
        id: id,
        every: {5, :minute},
        request: [
          url: {:secret, :hapn_device},
          params: %{"key" => {:secret, :hapn_secret}}
        ],
        facts: [%{path: [:test_poll, id, :temp], from: ["temp"]}],
        req_options: opts
      }

      {:ok, pid} = Source.HttpPoll.start_link(spec)
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

      assert {:ok, 1} = Source.HttpPoll.poll_now(id)
      assert_receive {:query, %{"key" => "client-secret"}}
      assert Process.alive?(pid), "the poller died resolving its own configuration"
    end

    # Containment, independent of the specific bug above. Anything a poll can
    # raise -- a vendor returning a shape no codec expected, a bad option, a
    # library changing its contract on upgrade -- must stop at this process.
    test "a raise inside a poll is contained and the poller survives" do
      id = :"poll_#{uniq()}"

      opts =
        stub(:raiser, fn _conn ->
          raise ArgumentError, "a library did something unexpected"
        end)

      spec = %{
        id: id,
        every: {5, :minute},
        request: [url: {:secret, :hapn_device}],
        facts: [%{path: [:test_poll, id, :x], from: ["x"]}],
        req_options: opts
      }

      {:ok, pid} = Source.HttpPoll.start_link(spec)
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

      ref = Process.monitor(pid)

      # Repeatedly, because one survived raise proves nothing about a loop --
      # and a crash loop was the actual production symptom.
      for _ <- 1..5 do
        assert {:error, {:raised, _}} = Source.HttpPoll.poll_now(id)
      end

      refute_receive {:DOWN, ^ref, :process, _, _}, 100
      assert Process.alive?(pid)
    end

    test "fetches a token, then polls with it" do
      test_pid = self()
      id = :"poll_#{uniq()}"

      opts =
        stub(:hapn_ok, fn conn ->
          case conn.request_path do
            "/token" ->
              send(test_pid, :token_requested)
              Req.Test.json(conn, %{"access_token" => "tok-1", "expires_in" => 3600})

            _ ->
              auth = Plug.Conn.get_req_header(conn, "authorization")
              send(test_pid, {:polled, auth})
              Req.Test.json(conn, %{"result" => %{"speed" => 42}})
          end
        end)

      start_poller(id, opts)
      assert {:ok, 1} = Source.HttpPoll.poll_now(id)

      assert_receive :token_requested
      assert_receive {:polled, ["Bearer tok-1"]}
      assert World.get([:test_poll, id, :speed]) == 42
    end

    test "does NOT re-request a token on every poll — bug 3" do
      # hapn_tracker.py derived token age from last_run, which it updated on
      # every tick, so the 55-minute condition was never true and refresh
      # never happened proactively. The inverse mistake -- refreshing on every
      # poll -- would be just as wrong, so assert the count.
      counter = :counters.new(1, [])
      id = :"poll_#{uniq()}"

      opts =
        stub(:hapn_count, fn conn ->
          case conn.request_path do
            "/token" ->
              :counters.add(counter, 1, 1)
              Req.Test.json(conn, %{"access_token" => "tok", "expires_in" => 3600})

            _ ->
              Req.Test.json(conn, %{"result" => %{"speed" => 1}})
          end
        end)

      start_poller(id, opts)

      for _ <- 1..5, do: Source.HttpPoll.poll_now(id)

      assert :counters.get(counter, 1) == 1,
             "the token was fetched #{:counters.get(counter, 1)} times across 5 polls"
    end

    test "the refresh deadline comes from expires_in, not from poll time" do
      # The heart of bug 3: two different clocks that the Python conflated.
      id = :"poll_#{uniq()}"

      opts =
        stub(:hapn_expiry, fn conn ->
          case conn.request_path do
            "/token" -> Req.Test.json(conn, %{"access_token" => "t", "expires_in" => 100})
            _ -> Req.Test.json(conn, %{"result" => %{"speed" => 1}})
          end
        end)

      start_poller(id, opts)
      Source.HttpPoll.poll_now(id)

      expires_at = Source.HttpPoll.token_expires_at(id)
      remaining = expires_at - System.monotonic_time(:millisecond)

      # 80% of a 100-second token: ~80s away, and definitely not derived from
      # the poll interval, which is an hour.
      assert remaining > 70_000 and remaining < 81_000,
             "refresh deadline is #{remaining}ms away; expected ~80s from expires_in"
    end

    test "a token that expires is renewed on the next poll" do
      counter = :counters.new(1, [])
      id = :"poll_#{uniq()}"

      opts =
        stub(:hapn_short, fn conn ->
          case conn.request_path do
            "/token" ->
              :counters.add(counter, 1, 1)
              # Zero life: the refresh deadline is already in the past, so the
              # next poll must renew.
              Req.Test.json(conn, %{"access_token" => "t", "expires_in" => 0})

            _ ->
              Req.Test.json(conn, %{"result" => %{"speed" => 1}})
          end
        end)

      start_poller(id, opts)
      Source.HttpPoll.poll_now(id)
      Source.HttpPoll.poll_now(id)

      assert :counters.get(counter, 1) == 2, "an expired token was not renewed"
    end

    test "a 403 discards the token so the next poll renews it" do
      # The reactive path, kept as a backstop rather than as the mechanism.
      id = :"poll_#{uniq()}"

      opts =
        stub(:hapn_403, fn conn ->
          case conn.request_path do
            "/token" -> Req.Test.json(conn, %{"access_token" => "t", "expires_in" => 3600})
            _ -> Plug.Conn.send_resp(conn, 403, "")
          end
        end)

      start_poller(id, opts)
      assert {:error, :unauthorised} = Source.HttpPoll.poll_now(id)
      assert Source.HttpPoll.token_expires_at(id) == nil
    end
  end

  describe "the poller under transport failure" do
    test "a transport error leaves the previous facts in place" do
      # A dropped network is not a reason to forget where the car was. The
      # fact ages instead, and its stale_after decides when "we last knew"
      # becomes "we do not know".
      id = :"poll_#{uniq()}"
      path = [:test_poll, id, :speed]

      good =
        stub(:hapn_good, fn conn ->
          case conn.request_path do
            "/token" -> Req.Test.json(conn, %{"access_token" => "t", "expires_in" => 3600})
            _ -> Req.Test.json(conn, %{"result" => %{"speed" => 55}})
          end
        end)

      {:ok, pid} = Source.HttpPoll.start_link(poller_spec(id, good))
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

      Source.HttpPoll.poll_now(id)
      assert World.get(path) == 55

      # Now the network goes away.
      Req.Test.stub(:hapn_good, fn conn -> Req.Test.transport_error(conn, :nxdomain) end)

      assert {:error, _} = Source.HttpPoll.poll_now(id)

      assert World.get(path) == 55,
             "a failed poll discarded the last known value instead of letting it age"
    end

    test "the poller survives a failed poll and keeps serving" do
      id = :"poll_#{uniq()}"

      opts =
        stub(:hapn_flaky, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      pid = start_poller(id, opts)

      assert {:error, _} = Source.HttpPoll.poll_now(id)
      assert Process.alive?(pid), "a transport failure killed the poller"

      assert {:error, _} = Source.HttpPoll.poll_now(id)
      assert Process.alive?(pid)
    end

    test "a 500 from the device endpoint is an error, not a crash" do
      id = :"poll_#{uniq()}"

      opts =
        stub(:hapn_500, fn conn ->
          case conn.request_path do
            "/token" -> Req.Test.json(conn, %{"access_token" => "t", "expires_in" => 3600})
            _ -> Plug.Conn.send_resp(conn, 500, "")
          end
        end)

      pid = start_poller(id, opts)
      assert {:error, {:http_status, 500}} = Source.HttpPoll.poll_now(id)
      assert Process.alive?(pid)
    end

    test "a malformed auth response does not install a token" do
      id = :"poll_#{uniq()}"

      opts =
        stub(:hapn_badauth, fn conn ->
          case conn.request_path do
            "/token" -> Req.Test.json(conn, %{"not_a_token" => true})
            _ -> Req.Test.json(conn, %{"result" => %{"speed" => 1}})
          end
        end)

      start_poller(id, opts)
      assert {:error, :no_access_token} = Source.HttpPoll.poll_now(id)
      assert Source.HttpPoll.token_expires_at(id) == nil
    end

    test "a missing optional field does not discard the fields that arrived" do
      id = :"poll_#{uniq()}"

      spec = %{
        id: id,
        every: {1, :hour},
        request: [url: {:secret, :hapn_device}],
        root: "result",
        facts: [
          %{path: [:test_poll, id, :speed], from: ["speed"]},
          %{path: [:test_poll, id, :battery], from: ["batteryPercentage"]}
        ],
        req_options:
          stub(:hapn_partial, fn conn ->
            Req.Test.json(conn, %{"result" => %{"speed" => 30}})
          end)
      }

      {:ok, pid} = Source.HttpPoll.start_link(spec)
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

      assert {:ok, 1} = Source.HttpPoll.poll_now(id)
      assert World.get([:test_poll, id, :speed]) == 30
      refute World.known?([:test_poll, id, :battery])
    end
  end

  describe "secrets never reach a log" do
    test "redact/1 replaces every secret value, and leaves non-secrets alone" do
      # Note what this asserts about scope: redaction is by VALUE, so anything
      # in the secrets map is redacted wherever it appears -- including
      # endpoint URLs, which are secrets in this configuration. That is the
      # conservative direction and the right one: a redactor that tried to
      # judge which secrets were "really" sensitive would eventually judge
      # wrong, and the failure is silent.
      state = %{
        auth: [client_secret: "client-secret", url: "https://hapn.example/token"],
        poller: :hapn,
        interval_ms: 60_000
      }

      redacted = Secrets.redact(state)
      rendered = inspect(redacted)

      refute rendered =~ "client-secret"
      refute rendered =~ "hapn.example"

      # Structure and non-secret values survive, so a redacted crash report is
      # still worth reading.
      assert rendered =~ ":hapn"
      assert rendered =~ "60000"
      assert rendered =~ "client_secret:"
    end

    test "a poller failure log does not contain the client secret" do
      id = :"poll_#{uniq()}"

      opts =
        stub(:hapn_leak, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          start_poller(id, opts)
          Source.HttpPoll.poll_now(id)
        end)

      refute log =~ "client-secret",
             "the client secret appeared in a failure log"
    end
  end

  describe "the settle window covers adapters, not only rules" do
    # Adapters reach the broker through Merlin.MQTT.Connection directly,
    # bypassing Merlin.Effects entirely -- so the settle window has to be
    # applied in both places or it has a hole exactly the width of every
    # adapter.
    #
    # Nothing in the shipped configuration emits a publish from an adapter
    # today: the ping/pong harness is a declarative source plus a rule, and
    # `Merlin.Adapters.Echo` is used by nothing but its own unit test. So a
    # mutation deleting this guard survived the whole battery, because the
    # guarded path is unreachable from the config.
    #
    # It is still a real guard: `{:publish, topic, payload, opts}` is part of
    # the documented adapter contract, and the next adapter to use it should
    # not have to rediscover that retained-message replay exists. Testing it
    # directly is the difference between a defence and a hope.
    setup do
      Merlin.Settle.finish()
      on_exit(&Merlin.Settle.finish/0)
      :ok
    end

    defp start_connection do
      {:ok, pid} =
        GenServer.start_link(
          Merlin.MQTT.Connection,
          [
            client: Merlin.Test.FakeBroker,
            adapters: [{Merlin.Adapters.Echo, []}],
            client_id: "settle-adapter-test",
            host: "fake",
            port: 0
          ],
          name: Merlin.MQTT.Connection
        )

      broker = Process.whereis(Merlin.Test.FakeBroker)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.unlink(pid)
          Process.exit(pid, :kill)
        end
      end)

      {pid, broker}
    end

    defp sync(pid) do
      :sys.get_state(pid, 1_000)
      Process.sleep(20)
      :sys.get_state(pid, 1_000)
    end

    test "an adapter's publish is held while settling" do
      {pid, broker} = start_connection()

      Merlin.Settle.begin("test", 10_000)
      Merlin.Test.FakeBroker.connect(broker)
      sync(pid)
      Merlin.Test.FakeBroker.clear_published(broker)

      Merlin.Test.FakeBroker.device_publish(broker, "test/ping", "hello")
      sync(pid)

      assert Merlin.Test.FakeBroker.published(broker) == [],
             "an adapter published during the settle window"
    end

    test "and goes through once the window closes" do
      {pid, broker} = start_connection()

      Merlin.Settle.begin("test", 10_000)
      Merlin.Test.FakeBroker.connect(broker)
      sync(pid)
      Merlin.Test.FakeBroker.clear_published(broker)

      # The other half of the assertion. A window that never reopened would
      # satisfy the test above perfectly.
      Merlin.Settle.finish()
      Merlin.Test.FakeBroker.device_publish(broker, "test/ping", "hello")
      sync(pid)

      assert [{"test/pong", "pong"}] = Merlin.Test.FakeBroker.published(broker)
    end
  end
end
