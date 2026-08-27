defmodule Merlin.HTTP.PublicRouter do
  @moduledoc """
  The internet-reachable listener: `POST /snitch` and `GET /healthz`.

  Nothing else lives here. The dashboard and `/facts.json` reveal whether the
  house is occupied and where the vehicle is, and they belong on the loopback
  listener -- see `Merlin.HTTP.LocalRouter`. Two Bandit instances is a two-line
  cost for a genuine separation of exposure.

  ## /snitch always answers 200

  Deliberate, and carried over from `api.py`. A valid key, an unknown key, a
  revoked key, malformed JSON, an oversized body and an internal error are all
  indistinguishable to the caller, so the endpoint cannot be used as an oracle
  to test whether a key is live.

  The accepted cost, stated rather than papered over: a timing side channel
  remains, since a valid key does more work than an invalid one. Padding
  responses to a fixed duration is theatre for a home endpoint behind a
  domestic connection, and the always-200 behaviour is the protection that
  actually matters.
  """

  use Plug.Router

  require Logger

  alias Merlin.{Ingress, KeyStore}

  plug(Merlin.HTTP.AccessLog)
  plug(:match)
  plug(:dispatch)

  # Body size cap. A home endpoint has no business accepting a large body, and
  # an unbounded one is trivial memory exhaustion.
  @max_body 32_000

  # --- POST /snitch ---------------------------------------------------------

  post "/snitch" do
    # Plug.Parsers is deliberately NOT used here. It *raises* on malformed
    # JSON, which becomes a 400 -- and a 400 for bad JSON against a 200 for an
    # unknown key makes this endpoint an oracle for whether a key is live,
    # which is the one thing the always-200 rule exists to prevent. Tier 4
    # caught exactly that. Reading and decoding by hand makes malformed input
    # an ordinary branch.
    conn =
      if Merlin.HTTP.RateLimit.allow?(conn.remote_ip) do
        {conn, body} = read_capped(conn)
        handle_snitch(body, api_key_header(conn))
        conn
      else
        conn
      end

    # Always 200. See the moduledoc.
    send_resp(conn, 200, "OK")
  end

  # Returns at most @max_body bytes and discards the rest without buffering it.
  defp read_capped(conn) do
    case Plug.Conn.read_body(conn, length: @max_body, read_length: @max_body) do
      {:ok, body, conn} -> {conn, body}
      {:more, _partial, conn} -> {discard(conn), :too_large}
      {:error, _reason} -> {conn, :unreadable}
    end
  end

  defp discard(conn) do
    case Plug.Conn.read_body(conn, length: @max_body, read_length: @max_body) do
      {:ok, _, conn} -> conn
      {:more, _, conn} -> discard(conn)
      {:error, _} -> conn
    end
  end

  # --- GET /healthz ---------------------------------------------------------

  get "/healthz" do
    connected? = safe(fn -> Merlin.MQTT.Connection.connected?() end, false)
    facts = safe(fn -> length(Merlin.World.dump()) end, 0)
    rules = safe(fn -> length(Merlin.Rules.Engine.rules()) end, 0)

    body =
      Jason.encode!(%{
        status: if(connected?, do: "ok", else: "degraded"),
        mqtt: if(connected?, do: "connected", else: "disconnected"),
        facts: facts,
        rules: rules,
        dry_run: Merlin.Config.dry_run?(),
        version: Application.spec(:merlin, :vsn) |> to_string()
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(if(connected?, do: 200, else: 503), body)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # --- the handler ----------------------------------------------------------

  # Never returns anything the caller can distinguish; its only job is the
  # side effect. Wrapped, because a raise here would still owe the client a
  # response and must not become a 500 that leaks which branch it reached.
  # The always-200 rule is about what the CLIENT learns, not what the operator
  # does. Collapsing every failure into a silent `:ok` meant a phone posting a
  # wrong key, a missing field or malformed JSON all produced an empty log and
  # a 200, with no way to tell them apart -- which is exactly the position this
  # deployment was in for an afternoon.
  #
  # The reason is logged; the key never is. A key's first eight characters are
  # stored precisely so a key can be identified without its secret, and eight
  # characters of a 192-bit key identify nothing on their own.
  # Two shapes, because the credential and the payload are different things
  # and only one of them is merlin's business.
  #
  #   * `x-api-key: <key>` (or `authorization: Bearer <key>`) with the body as
  #     the payload, verbatim. The device posts whatever it natively posts.
  #   * `{"challenge": ..., "status": ...}` -- the Python's envelope, kept
  #     working because things already use it.
  #
  # The header form is the better one and should have been the original. A
  # credential in the body forces the body into merlin's envelope, which means
  # the device has to be reconfigured to merlin's shape rather than merlin
  # accepting the device's -- and a device is usually the thing you cannot
  # change or test.
  # `read_capped/1` answers :too_large or :unreadable rather than a body.
  defp handle_snitch(body, _key) when not is_binary(body) do
    Logger.info("snitch rejected: #{body}")
    :ok
  end

  defp handle_snitch(body, header_key) when is_binary(header_key) do
    case lookup(header_key) do
      {:ok, topic, id} ->
        Ingress.inject(topic, body, source: {:http, id})
        KeyStore.with_db(fn db -> KeyStore.touch(db, id) end)

      :error ->
        Logger.info(
          "snitch rejected: key #{key_prefix(header_key)} from the header is not " <>
            "recognised, or is revoked or expired. `merlin-key list` shows what is accepted."
        )

        :ok
    end
  end

  defp handle_snitch(body, _no_header) do
    case decode_snitch(body) do
      {:ok, challenge, status} ->
        case lookup(challenge) do
          {:ok, topic, id} ->
            payload = if is_binary(status), do: status, else: Jason.encode!(status)
            Ingress.inject(topic, payload, source: {:http, id})
            KeyStore.with_db(fn db -> KeyStore.touch(db, id) end)

          :error ->
            Logger.info(
              "snitch rejected: key #{key_prefix(challenge)} is not recognised, or is " <>
                "revoked or expired. `merlin-key list` shows what is accepted."
            )

            :ok
        end

      {:error, reason} ->
        Logger.info("snitch rejected: #{reason}")
        :ok
    end
  rescue
    e ->
      # No key material in this message: `e` is an exception, not the body.
      Logger.warning("snitch handler raised: #{Exception.message(e)}")
      :ok
  end

  # `x-api-key` first, then `authorization: Bearer`. Both are conventional and
  # neither costs anything to accept.
  defp api_key_header(conn) do
    case Plug.Conn.get_req_header(conn, "x-api-key") do
      [key | _] when is_binary(key) and key != "" ->
        key

      _ ->
        case Plug.Conn.get_req_header(conn, "authorization") do
          ["Bearer " <> key | _] when key != "" -> key
          ["bearer " <> key | _] when key != "" -> key
          _ -> nil
        end
    end
  end

  # Every way a body can fail to be a position report, named.
  defp decode_snitch(body) do
    case Jason.decode(body) do
      {:ok, %{"challenge" => c, "status" => s}} when is_binary(c) and not is_nil(s) ->
        {:ok, c, s}

      {:ok, %{"challenge" => c, "status" => nil}} when is_binary(c) ->
        {:error, "the `status` field is null"}

      {:ok, %{"challenge" => c}} when is_binary(c) ->
        {:error, "no `status` field"}

      {:ok, %{"challenge" => c}} ->
        {:error, "`challenge` is a #{type_name(c)}, not a string"}

      {:ok, map} when is_map(map) ->
        {:error, "no `challenge` field; the body has #{inspect(Map.keys(map))}"}

      {:ok, other} ->
        {:error, "the body is a #{type_name(other)}, not an object"}

      {:error, _} ->
        {:error, "the body is not valid JSON (#{byte_size(body)} bytes)"}
    end
  end

  defp key_prefix(challenge) when is_binary(challenge) do
    binary_part(challenge, 0, min(8, byte_size(challenge))) <> "..."
  end

  defp type_name(v) when is_binary(v), do: "string"
  defp type_name(v) when is_number(v), do: "number"
  defp type_name(v) when is_list(v), do: "array"
  defp type_name(v) when is_map(v), do: "object"
  defp type_name(v) when is_boolean(v), do: "boolean"
  defp type_name(nil), do: "null"
  defp type_name(_), do: "value"

  defp lookup(challenge) do
    KeyStore.with_db(fn conn -> KeyStore.resolve(conn, challenge) end)
  end

  defp safe(fun, default) do
    fun.()
  rescue
    _ -> default
  catch
    :exit, _ -> default
  end
end
