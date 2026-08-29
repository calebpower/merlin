defmodule Merlin.Control do
  @moduledoc """
  The only way an operator changes anything, and it takes two steps.

  ## Why two steps

  A one-shot `do_this(command)` means the thing the operator *read* and the
  thing that *executed* are related only by hope. A mis-wired keybinding, a
  stale screen, a command line that lost focus -- each turns into an actuation
  nobody chose.

  So: `prepare/2` resolves a command into concrete effects, describes them in
  the words `Merlin.Effects.describe/1` would use, and mints a token.
  `commit/3` executes *that token's already-resolved effects* and nothing else.
  The description the operator confirmed is therefore the description of what
  runs. Re-resolving at commit time would reintroduce exactly the race this
  exists to close.

  ## What may be commanded

  An allowlist of three, deliberately: command a group, publish a topic, write
  a fact. Not an eval. `bin/merlind remote` already exists and is honest about
  being a shell; a control surface that can run arbitrary code is that with a
  nicer font, and it would be reachable by anything that could reach this.

  ## What needs confirming

  `Merlin.Settle.suppresses?/1` already defines "outward actuation" and is
  tested as a policy in its own right, so it is reused rather than restated --
  a second definition of the same idea is how the last several defects in this
  codebase got in.

  One thing is added to it, explicitly rather than by redefinition: writing a
  fact. A fact is not outward, so the settle window rightly lets it through --
  learning is the point of the window. But a fact written by hand can wedge a
  latch into a state that then *survives into the snapshot* and outlives the
  session that set it. That earns a confirmation even though it actuates
  nothing.

  ## Provenance

  Every commit runs through `Merlin.Effects.perform/2` with an explicit
  `source: {:operator, who}`. Never `Groups.set/2`, which would bypass dry-run,
  bypass the settle window, and leave no log line -- so that the morning
  question "did the printer power-cycle because of the load-shed machine or
  because somebody leaned on a key over SSH?" has an answer.
  """

  use GenServer

  require Logger

  alias Merlin.{Config, Effects, Groups, Settle}

  # Long enough to read a description and decide, short enough that a token
  # left on a screen overnight is not a live command in the morning.
  @ttl_ms 30_000

  defmodule Prepared do
    @moduledoc "A resolved command, awaiting confirmation."

    @enforce_keys [:token, :effects, :description, :requester, :expires_at, :confirm?, :dry_run?]
    defstruct [:token, :effects, :description, :requester, :expires_at, :confirm?, :dry_run?]

    @type t :: %__MODULE__{
            token: binary(),
            effects: [Merlin.Effects.effect()],
            description: [binary()],
            requester: pid(),
            expires_at: integer(),
            confirm?: boolean(),
            dry_run?: boolean()
          }
  end

  @type command ::
          {:set_group, atom(), term()}
          | {:publish, binary(), binary()}
          | {:set_fact, Merlin.Path.t(), term()}

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Resolve a command and mint a token for it.

  Returns `{:ok, %Prepared{}}` or `{:error, reason}`. Nothing has happened yet.

  Options:

    * `:ttl_ms` -- how long the token stays redeemable. Defaults to
      `ttl_ms/0`. Exists so the expiry branch is testable in under a second
      rather than only by waiting thirty of them, which is the same reason no
      test ever covered it.
  """
  @spec prepare(command(), pid(), keyword()) :: {:ok, Prepared.t()} | {:error, term()}
  def prepare(command, requester \\ self(), opts \\ []) do
    GenServer.call(__MODULE__, {:prepare, command, requester, opts})
  end

  @doc """
  Execute a prepared command.

  Options:

    * `:dry_run` -- override the daemon's setting for this command only. This
      is how an operator actuates for real during a dry-run soak: per command,
      individually consented, with the global posture untouched. There is
      deliberately no runtime toggle -- see the moduledoc of `Merlin.Effects`.
    * `:who` -- the operator, for the log. Defaults to "unknown".
  """
  @spec commit(binary(), pid(), keyword()) :: {:ok, [Merlin.Effects.effect()]} | {:error, term()}
  def commit(token, requester \\ self(), opts \\ []) do
    GenServer.call(__MODULE__, {:commit, token, requester, opts})
  end

  @doc "Discard a prepared command without running it."
  @spec cancel(binary(), pid()) :: :ok
  def cancel(token, requester \\ self()) do
    GenServer.call(__MODULE__, {:cancel, token, requester})
  end

  @doc false
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @doc "How many tokens are outstanding. For tests and diagnostics."
  @spec outstanding() :: non_neg_integer()
  def outstanding, do: GenServer.call(__MODULE__, :outstanding)

  @doc """
  Whether these effects need confirming before they run.

  Composed from `Settle.suppresses?/1` rather than restating it, plus the
  fact-write case the settle window deliberately permits.
  """
  @spec confirmable?([Merlin.Effects.effect()]) :: boolean()
  def confirmable?(effects) do
    Enum.any?(effects, fn effect ->
      Settle.suppresses?(effect) or writes_world?(effect)
    end)
  end

  defp writes_world?({:set_fact, _path, _value}), do: true
  defp writes_world?(_), do: false

  @doc "The TTL applied to a minted token."
  @spec ttl_ms() :: pos_integer()
  def ttl_ms, do: @ttl_ms

  # --- resolution -----------------------------------------------------------

  @doc """
  Turn a command into effects, without minting anything.

  Public so the allowlist is testable as a pure function rather than only
  through a running GenServer.
  """
  @spec resolve(command()) :: {:ok, [Merlin.Effects.effect()]} | {:error, term()}
  def resolve({:set_group, group, value}) when is_atom(group) do
    cond do
      not Map.has_key?(Config.groups(), group) ->
        {:error, {:unknown_group, group}}

      Groups.members(group) == [] ->
        {:error, {:group_has_no_members, group}}

      not is_binary(Config.groups()[group][:set_topic]) ->
        # A members-only group names a set of facts and has nowhere to publish.
        # Commanding one is refused at boot for a rule; refuse it here too,
        # rather than emitting an effect that can only fail.
        {:error, {:group_not_commandable, group}}

      true ->
        {:ok, [{:set_group, group, value}]}
    end
  end

  def resolve({:publish, topic, payload}) when is_binary(topic) and is_binary(payload) do
    if String.contains?(topic, ["+", "#"]) do
      # A wildcard is a subscription pattern, not an address. Publishing to one
      # is silently accepted by some brokers and dropped by others.
      {:error, {:wildcard_topic, topic}}
    else
      {:ok, [{:publish, topic, payload, []}]}
    end
  end

  def resolve({:set_fact, path, value}) when is_list(path) and path != [] do
    {:ok, [{:set_fact, path, value}]}
  end

  def resolve(other), do: {:error, {:not_a_command, other}}

  # --- server ---------------------------------------------------------------

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:prepare, command, requester, opts}, _from, tokens) do
    case resolve(command) do
      {:ok, effects} ->
        ttl = Keyword.get(opts, :ttl_ms, @ttl_ms)

        prepared = %Prepared{
          token: mint(),
          effects: effects,
          description: Enum.map(effects, &Effects.describe/1),
          requester: requester,
          expires_at: System.monotonic_time(:millisecond) + ttl,
          confirm?: confirmable?(effects),
          dry_run?: Config.dry_run?()
        }

        {:reply, {:ok, prepared}, Map.put(expire(tokens), prepared.token, prepared)}

      {:error, _} = error ->
        {:reply, error, expire(tokens)}
    end
  end

  @impl true
  def handle_call({:commit, token, requester, opts}, _from, tokens) do
    tokens = expire(tokens)

    case Map.fetch(tokens, token) do
      # Same session only. A token is a decision made by one operator at one
      # screen; letting another process redeem it would make the confirmation
      # a formality.
      {:ok, %Prepared{requester: ^requester} = prepared} ->
        who = Keyword.get(opts, :who, "unknown")

        perform_opts =
          [source: {:operator, who}] ++
            case Keyword.fetch(opts, :dry_run) do
              {:ok, value} -> [dry_run: value]
              :error -> []
            end

        Logger.info(
          "operator #{who} committed: #{Enum.join(prepared.description, "; ")}" <>
            if(Keyword.get(opts, :dry_run) == false, do: " [OVERRIDING DRY RUN]", else: "")
        )

        Effects.perform(prepared.effects, perform_opts)
        {:reply, {:ok, prepared.effects}, Map.delete(tokens, token)}

      {:ok, %Prepared{}} ->
        {:reply, {:error, :wrong_requester}, tokens}

      :error ->
        # Covers both "never existed" and "expired", and deliberately does not
        # distinguish them: a token is not a secret worth probing, but neither
        # is there any use in the difference.
        {:reply, {:error, :unknown_token}, tokens}
    end
  end

  @impl true
  def handle_call({:cancel, token, requester}, _from, tokens) do
    tokens =
      case Map.fetch(tokens, token) do
        {:ok, %Prepared{requester: ^requester}} -> Map.delete(tokens, token)
        _ -> tokens
      end

    {:reply, :ok, expire(tokens)}
  end

  @impl true
  def handle_call(:reset, _from, _tokens), do: {:reply, :ok, %{}}

  @impl true
  def handle_call(:outstanding, _from, tokens) do
    tokens = expire(tokens)
    {:reply, map_size(tokens), tokens}
  end

  # Swept on every call rather than on a timer: the table is tiny, the sweep is
  # a map filter, and a timer would be a process that can be alive while the
  # thing it sweeps is not.
  defp expire(tokens) do
    now = System.monotonic_time(:millisecond)
    Map.reject(tokens, fn {_token, %Prepared{expires_at: at}} -> at <= now end)
  end

  defp mint, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
