defmodule Merlin.Source.HttpPoll do
  @moduledoc """
  Polls an HTTP endpoint on an interval and writes the response into facts.

      %{
        id: :weather,
        every: {5, :minute},
        request: [url: {:secret, :weather_endpoint}],
        facts: [%{path: [:weather, :exterior, :temp_f], from: ["temp"]}]
      }

  ## Bug 3, and why the fix is not a smaller constant

  `hapn_tracker.py` refreshed its OAuth token when
  `last_run + 55 minutes < now`, and set `last_run = now` at the end of
  **every** tick -- including ticks that did no refresh. At a 60-second
  interval `last_run` was therefore never more than a minute old, the
  condition was never true, and proactive refresh never happened once. The
  token was only ever renewed reactively, by a 403 that had already cost a
  poll.

  The fix is not a shorter interval. It is to stop deriving token age from
  poll time at all: the server tells us `expires_in`, so this records
  `expires_at` when the token is issued and refreshes at 80% of its life. Two
  different clocks that were conflated into one.

  ## Failures are expected, not exceptional

  A home network drops, a vendor API 500s, DNS goes away for thirty seconds.
  None of that is a reason to crash: a failed tick logs, leaves the previous
  facts in place, and tries again next interval. The facts then age naturally
  and their `stale_after` decides when "we last knew" becomes "we do not
  know" -- which is the honest answer and the one the Python could not give,
  because it recorded a check-in timestamp that nothing ever read.
  """

  use GenServer
  require Logger

  alias Merlin.{Codec, Machine, Secrets, World}

  defstruct [
    :id,
    :interval_ms,
    :request,
    :decode,
    :facts,
    :root,
    :auth,
    :token,
    :token_expires_at,
    :stale_after_ms,
    :req_options,
    failures: 0
  ]

  # Refresh at 80% of the token's stated life: early enough that a slow
  # refresh does not strand a poll, late enough not to churn.
  @refresh_at 0.8

  @doc false
  def child_spec(spec), do: %{id: {__MODULE__, spec.id}, start: {__MODULE__, :start_link, [spec]}}

  @doc false
  def start_link(spec), do: GenServer.start_link(__MODULE__, spec, name: via(spec.id))

  defp via(id), do: {:via, Registry, {Merlin.Derive.Registry, {__MODULE__, id}}}

  @doc "Poll once, now, and return the outcome. For tests and diagnostics."
  @spec poll_now(atom()) :: {:ok, non_neg_integer()} | {:error, term()}
  def poll_now(id), do: GenServer.call(via(id), :poll_now, 30_000)

  @doc "Current token expiry, or nil. Exposed so a test can assert the refresh schedule."
  @spec token_expires_at(atom()) :: integer() | nil
  def token_expires_at(id), do: GenServer.call(via(id), :token_expires_at)

  @impl true
  def init(spec) do
    {:ok, interval_ms} = Machine.to_ms(spec[:every] || {5, :minute})

    state = %__MODULE__{
      id: spec.id,
      interval_ms: interval_ms,
      request: spec[:request] || [],
      decode: spec[:decode] || :json,
      facts: spec[:facts] || [],
      root: spec[:root],
      auth: spec[:auth],
      stale_after_ms: spec[:stale_after_ms],
      # Req options, overridable so tier 5 can inject a stub adapter and
      # transport failures without a network.
      req_options: spec[:req_options] || Application.get_env(:merlin, :req_options, [])
    }

    # First tick is scheduled, not immediate. The Python polled instantly at
    # boot, before the MQTT client existed, so the very first tick of every
    # runner ran with `self.mqtt = None`.
    schedule(state, 1_000)
    {:ok, state}
  end

  @impl true
  def handle_call(:poll_now, _from, state) do
    {result, state} = poll(state)
    {:reply, result, state}
  end

  def handle_call(:token_expires_at, _from, state), do: {:reply, state.token_expires_at, state}

  @impl true
  def handle_info(:tick, state) do
    {_result, state} = poll(state)
    schedule(state, state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp schedule(_state, ms), do: Process.send_after(self(), :tick, ms)

  # --- polling --------------------------------------------------------------

  # A vendor integration must not be able to kill the house.
  #
  # Without this, one unhandled raise in a poll became: GenServer exit ->
  # supervisor restart -> raise again, roughly once a second, until the restart
  # intensity was exhausted and the ENTIRE application shut down. A weather
  # endpoint took the door sensors and the printer with it. Nothing that talks
  # to someone else's server gets to do that.
  defp poll(state) do
    do_poll(state)
  rescue
    e ->
      Logger.error(
        "#{state.id}: poll raised #{inspect(e.__struct__)} -- contained; the poller stays up\n" <>
          Exception.format(:error, e, __STACKTRACE__)
      )

      {{:error, {:raised, e.__struct__}}, %{state | failures: state.failures + 1}}
  end

  defp do_poll(state) do
    with {:ok, state} <- ensure_token(state),
         {:ok, body} <- fetch(state) do
      written = write_facts(state, body)
      {{:ok, written}, %{state | failures: 0}}
    else
      {:error, :unauthorised, state} ->
        # The reactive path, kept as a backstop rather than as the mechanism.
        # A 401/403 means the token died early -- revoked, or the server
        # disagreed about its life -- so drop it and let the next tick renew.
        Logger.warning("#{state.id}: rejected by the server; discarding the token")
        {{:error, :unauthorised}, %{state | token: nil, token_expires_at: nil}}

      {:error, reason} ->
        failures = state.failures + 1

        Logger.warning(
          "#{state.id}: poll failed (#{failures} consecutive): #{inspect(reason)} " <>
            "-- previous facts left in place to age out"
        )

        {{:error, reason}, %{state | failures: failures}}
    end
  end

  defp fetch(state) do
    options =
      state.request
      |> Secrets.resolve_deep()
      |> Keyword.merge(state.req_options)
      |> put_auth_header(state.token)
      |> Keyword.put_new(:receive_timeout, 10_000)
      |> Keyword.put_new(:retry, false)

    case Req.request(options) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status}} when status in [401, 403] ->
        {:error, :unauthorised, state}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp put_auth_header(options, nil), do: options

  defp put_auth_header(options, token) do
    headers = Keyword.get(options, :headers, [])
    Keyword.put(options, :headers, [{"authorization", "Bearer " <> token} | headers])
  end

  # --- the token lifecycle --------------------------------------------------

  defp ensure_token(%{auth: nil} = state), do: {:ok, state}

  defp ensure_token(state) do
    if token_fresh?(state), do: {:ok, state}, else: refresh_token(state)
  end

  # Age is measured against the token's OWN expiry, recorded when it was
  # issued -- never against when we last polled. That conflation is bug 3.
  defp token_fresh?(%{token: nil}), do: false
  defp token_fresh?(%{token_expires_at: nil}), do: false

  defp token_fresh?(%{token_expires_at: expires_at}),
    do: System.monotonic_time(:millisecond) < expires_at

  defp refresh_token(state) do
    auth = Secrets.resolve_deep(state.auth)

    form = [
      grant_type: Keyword.get(auth, :grant_type, "client_credentials"),
      client_id: Keyword.fetch!(auth, :client_id),
      client_secret: Keyword.fetch!(auth, :client_secret)
    ]

    options =
      [url: Keyword.fetch!(auth, :url), form: form, receive_timeout: 10_000, retry: false]
      |> Keyword.merge(state.req_options)

    case Req.post(options) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        install_token(state, body)

      {:ok, %{status: status}} ->
        {:error, {:auth_status, status}}

      {:error, reason} ->
        {:error, {:auth_transport, reason}}
    end
  end

  defp install_token(state, body) when is_map(body) do
    case Map.get(body, "access_token") do
      token when is_binary(token) ->
        # expires_in is what the server says the token is good for. Absent, an
        # hour is assumed -- and it is assumed conservatively, since refreshing
        # early costs one request and refreshing late costs a poll.
        lifetime_s = Map.get(body, "expires_in", 3600)

        expires_at =
          System.monotonic_time(:millisecond) + round(lifetime_s * 1_000 * @refresh_at)

        Logger.info("#{state.id}: token refreshed, renewing in #{round(lifetime_s * @refresh_at)}s")

        {:ok, %{state | token: token, token_expires_at: expires_at}}

      _ ->
        {:error, :no_access_token}
    end
  end

  defp install_token(_state, _body), do: {:error, :auth_response_not_json}

  # --- writing --------------------------------------------------------------

  # Fact specs use the same shape as a declarative MQTT source -- %{path:,
  # from:, codec:} -- rather than a second vocabulary for the same job. One
  # notation to learn, and the codecs are shared.
  defp write_facts(state, body) do
    root = if state.root, do: Map.get(body, state.root, body), else: body

    Enum.count(state.facts, fn spec ->
      case Codec.dig(root, Map.fetch!(spec, :from), Map.get(spec, :codec)) do
        {:ok, value} ->
          World.put(spec.path, value,
            source: {:poll, state.id},
            stale_after: state.stale_after_ms
          )

          true

        :error ->
          # One missing field is not a failed poll. A vendor dropping an
          # optional key should not discard the fields that did arrive.
          Logger.debug(fn -> "#{state.id}: no value at #{inspect(spec.from)}" end)
          false
      end
    end)
  end

end
