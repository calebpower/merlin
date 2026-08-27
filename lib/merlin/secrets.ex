defmodule Merlin.Secrets do
  @moduledoc """
  Credentials, kept apart from the configuration that references them.

      # merlin.exs, root-owned 0640, safe to read
      auth_endpoint: secret(:hapn_auth_endpoint)

      # merlin.secrets.exs, 0600 merlin:merlin
      %{hapn_auth_endpoint: "https://...", hapn_client_secret: "..."}

  ## Why a separate file

  `config.toml` in the Python held `client_secret`, `discord_webhook` and the
  weather `api_key` inline, which meant the file describing the house could
  not be read, copied, pasted into a message or committed without leaking
  credentials. It was gitignored, which protects the repository and nothing
  else.

  Splitting them means `merlin.exs` is a document about your house that you
  can show someone.

  ## What this module refuses to do

  It does not log secret values, and `resolve/1` returns them only to the
  caller that asked. `redact/1` is used wherever a config structure might be
  inspected -- an `inspect/1` of a poller's state in a crash report is exactly
  how a client secret ends up in a log that gets archived.

  The file's permissions are checked at load. A world-readable secrets file is
  a refusal to boot, not a warning: warnings are read once and then never
  again, and the failure mode here is silent and permanent.
  """

  require Logger

  @key {__MODULE__, :loaded}

  @typedoc "A reference to a secret, as it appears in configuration."
  @type ref :: {:secret, atom()}

  @doc "The path secrets are read from."
  @spec path() :: binary()
  def path do
    System.get_env("MERLIN_SECRETS") ||
      Application.get_env(:merlin, :secrets_path) ||
      Path.join(Path.dirname(Merlin.Config.path()), "merlin.secrets.exs")
  end

  @doc """
  Load the secrets file.

  Missing is not an error: a daemon with no pollers configured needs no
  secrets, and demanding the file would make the common case harder. A file
  that exists but is readable by anyone else IS an error.
  """
  @spec load(binary() | nil) :: :ok | {:error, term()}
  def load(from \\ nil) do
    file = from || path()

    cond do
      not File.exists?(file) ->
        :persistent_term.put(@key, %{})
        Logger.info("no secrets file at #{file}; continuing without one")
        :ok

      not restrictive?(file) ->
        {:error, {:permissions, file, mode(file)}}

      true ->
        case eval(file) do
          {:ok, map} when is_map(map) ->
            :persistent_term.put(@key, map)
            Logger.info("secrets loaded from #{file}: #{map_size(map)} entr(ies)")
            :ok

          {:ok, other} ->
            {:error, {:not_a_map, file, type_of(other)}}

          {:error, reason} ->
            {:error, {:eval_failed, file, reason}}
        end
    end
  end

  @doc """
  Resolve a value that may be a secret reference.

  Anything that is not a `{:secret, name}` tuple passes through untouched, so
  callers can hand configuration values straight in without checking first.
  """
  @spec resolve(term()) :: {:ok, term()} | {:error, {:missing_secret, atom()}}
  def resolve({:secret, name}) when is_atom(name) do
    case Map.fetch(loaded(), name) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_secret, name}}
    end
  end

  def resolve(value), do: {:ok, value}

  @doc "Resolve, raising on a missing secret. For call sites that cannot proceed without one."
  @spec resolve!(term()) :: term()
  def resolve!(value) do
    case resolve(value) do
      {:ok, resolved} ->
        resolved

      {:error, {:missing_secret, name}} ->
        raise ArgumentError, "secret #{inspect(name)} is referenced but not defined in #{path()}"
    end
  end

  @doc """
  Resolve every secret reference anywhere inside a term.

  This walks exactly the same shapes as `referenced/1`, and that is the point.
  A shallow resolver next to a deep validator is a trap: the validator sees a
  nested `{:secret, name}`, confirms it is defined, and passes -- and then the
  resolver hands the raw tuple to whatever consumes it. That is not a missing
  secret at boot, it is a crash on the first tick, in a poller, in production.

  Raises on a name that is referenced but not defined; the validator's job is
  to make that unreachable at boot.
  """
  @spec resolve_deep(term()) :: term()
  def resolve_deep({:secret, name} = ref) when is_atom(name), do: resolve!(ref)

  def resolve_deep(term) when is_map(term) and not is_struct(term),
    do: Map.new(term, fn {k, v} -> {resolve_deep(k), resolve_deep(v)} end)

  def resolve_deep(term) when is_list(term), do: Enum.map(term, &resolve_deep/1)

  def resolve_deep(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.map(&resolve_deep/1) |> List.to_tuple()

  def resolve_deep(term), do: term

  @doc """
  Every secret name a term references, without resolving any of them.

  Used by the boot validator to report *all* missing secrets at once rather
  than one per restart.
  """
  @spec referenced(term()) :: [atom()]
  def referenced({:secret, name}) when is_atom(name), do: [name]

  def referenced(term) when is_map(term) and not is_struct(term),
    do: term |> Map.to_list() |> Enum.flat_map(&referenced/1)

  def referenced(term) when is_list(term), do: Enum.flat_map(term, &referenced/1)

  def referenced(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.flat_map(&referenced/1)

  def referenced(_), do: []

  @doc "Names that are referenced but not defined."
  @spec missing(term()) :: [atom()]
  def missing(term) do
    defined = loaded() |> Map.keys() |> MapSet.new()

    term
    |> referenced()
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(defined, &1))
  end

  @doc """
  Replace secret values in a term with `:redacted`.

  For anywhere a structure might be inspected. A poller's state in a crash
  report is exactly how a client secret reaches an archived log.
  """
  @spec redact(term()) :: term()
  def redact(term) do
    values = loaded() |> Map.values() |> MapSet.new()
    do_redact(term, values)
  end

  defp do_redact(term, values) when is_binary(term) do
    if MapSet.member?(values, term), do: :redacted, else: term
  end

  defp do_redact({:secret, _} = ref, _values), do: ref

  defp do_redact(term, values) when is_map(term) and not is_struct(term),
    do: Map.new(term, fn {k, v} -> {k, do_redact(v, values)} end)

  defp do_redact(term, values) when is_list(term), do: Enum.map(term, &do_redact(&1, values))

  defp do_redact(term, values) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.map(&do_redact(&1, values)) |> List.to_tuple()

  defp do_redact(term, _values), do: term

  @doc "Install secrets directly. For tests."
  @spec put(map()) :: :ok
  def put(map) when is_map(map), do: :persistent_term.put(@key, map)

  @doc "The currently loaded secrets."
  @spec loaded() :: map()
  def loaded, do: :persistent_term.get(@key, %{})

  # --- file handling --------------------------------------------------------

  # 0600 or 0400. Group- or world-readable is a refusal, because the whole
  # point of the split is that this file is the one nobody else can read.
  defp restrictive?(file) do
    case mode(file) do
      nil -> false
      m -> Bitwise.band(m, 0o077) == 0
    end
  end

  defp mode(file) do
    case File.stat(file) do
      {:ok, %File.Stat{mode: mode}} -> Bitwise.band(mode, 0o777)
      _ -> nil
    end
  end

  # SECURITY: Code.eval_file/1 executes the file. Same trust argument as
  # Merlin.Config.File, and it applies more sharply here because this is the
  # secrets file:
  #
  #   * The path is fixed (MERLIN_SECRETS, else beside merlin.exs) and the
  #     mode is checked BEFORE evaluation -- group- or world-readable is a
  #     refusal to load, not a warning.
  #   * Anyone who can write this file already owns the daemon's credentials
  #     outright; executing it grants them nothing they did not have.
  #   * This is NOT a sandbox. There is no post-hoc check that could make it
  #     one, because a side effect during evaluation has already happened.
  #   * Therefore: never point MERLIN_SECRETS at a path anyone else can write.
  #     Not a shared directory, not a checkout, not anywhere a deploy process
  #     drops files with default permissions.
  #
  # `.exs` is used rather than a parsed format because the alternative --
  # inventing a key-value parser -- is more code for less clarity, and the
  # trust boundary would be identical either way: whoever writes this file
  # controls the daemon.
  defp eval(file) do
    {term, _bindings} = Code.eval_file(file)
    {:ok, term}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp type_of(term) when is_list(term), do: :list
  defp type_of(term) when is_binary(term), do: :binary
  defp type_of(_), do: :other
end
