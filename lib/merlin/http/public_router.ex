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
        handle_snitch(body)
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
  defp handle_snitch(body) when not is_binary(body), do: :ok

  defp handle_snitch(body) do
    with {:ok, %{"challenge" => challenge, "status" => status}} when is_binary(challenge) <-
           Jason.decode(body),
         false <- is_nil(status),
         {:ok, topic, id} <- lookup(challenge) do
      payload = if is_binary(status), do: status, else: Jason.encode!(status)
      Ingress.inject(topic, payload, source: {:http, id})
      KeyStore.with_db(fn db -> KeyStore.touch(db, id) end)
    else
      _ -> :ok
    end
  rescue
    e ->
      # No key material in this message: `e` is an exception, not the body.
      Logger.warning("snitch handler raised: #{Exception.message(e)}")
      :ok
  end

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
