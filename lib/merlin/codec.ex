defmodule Merlin.Codec do
  @moduledoc """
  Payload decoding, declared as data.

  A codec turns bytes off the wire into a value the fact store can hold. They
  are pure functions returning `{:ok, value}` or `:error`, and they never
  raise -- a device that changes its JSON shape in a firmware update must
  produce a dropped message and a log line, not a crash loop.

  ## Why `:error` rather than an exception

  `home_doors.py` wrapped its whole body in `try/except Exception`, and
  `livingroom_lamps.py` used a bare `except Exception: pass`. Both silently
  swallowed malformed payloads and left cached state stale with no signal at
  all. Returning `:error` keeps the same resilience while making the failure
  visible and countable.
  """

  @type spec ::
          :raw
          | :json
          | :integer
          | :float
          | {:enum, %{optional(binary()) => term()}}
          | {:json_path, [binary()], spec()}
          | {:truthy, term(), term()}

  @doc """
  Decode `payload` according to `spec`.

  Specs compose: `{:json_path, ["print_stats", "state"], {:enum, ...}}` pulls a
  nested field out of a JSON body and then maps it.
  """
  @spec decode(binary(), spec()) :: {:ok, term()} | :error
  def decode(payload, :raw) when is_binary(payload), do: {:ok, payload}

  def decode(payload, :json) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, value} -> {:ok, value}
      {:error, _} -> :error
    end
  end

  def decode(payload, :integer) when is_binary(payload) do
    case Integer.parse(String.trim(payload)) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  def decode(payload, :float) when is_binary(payload) do
    case Float.parse(String.trim(payload)) do
      {f, ""} -> {:ok, f}
      _ -> :error
    end
  end

  # An enum maps a closed set of wire values onto our vocabulary. Anything
  # outside the map is :error rather than a pass-through, so a device
  # inventing a new state cannot quietly become a fact nobody declared.
  def decode(payload, {:enum, mapping}) when is_map(mapping) do
    case Map.fetch(mapping, payload) do
      {:ok, value} -> {:ok, value}
      :error -> :error
    end
  end

  # Truthiness, for zigbee2mqtt's `contact: true` convention. The Python used
  # Python truthiness on the decoded JSON value; this is the same rule stated
  # explicitly rather than inherited from the language.
  def decode(value, {:truthy, when_true, when_false}) do
    {:ok, if(truthy?(value), do: when_true, else: when_false)}
  end

  def decode(payload, {:json_path, path, inner}) when is_binary(payload) do
    with {:ok, decoded} <- decode(payload, :json) do
      dig(decoded, path, inner)
    end
  end

  # Already-decoded values passing through a further spec.
  def decode(value, {:enum_value, mapping}) when is_map(mapping) do
    case Map.fetch(mapping, value) do
      {:ok, mapped} -> {:ok, mapped}
      :error -> :error
    end
  end

  def decode(_payload, _spec), do: :error

  @doc """
  Pull `path` out of an already-decoded JSON structure, then apply `inner`.

  Accepts a list of alternative paths, first match wins -- Moonraker reports
  print state as either `state` or `print_stats.state` depending on the
  message, and `klipper_monitor.py` handled both with an `or`.
  """
  @spec dig(term(), [binary()] | [[binary()]], spec()) :: {:ok, term()} | :error
  def dig(decoded, [head | _] = path, inner) when is_binary(head) do
    case get_in_safe(decoded, path) do
      {:ok, value} -> apply_inner(value, inner)
      :error -> :error
    end
  end

  def dig(decoded, alternatives, inner) when is_list(alternatives) do
    Enum.reduce_while(alternatives, :error, fn path, _acc ->
      case dig(decoded, path, inner) do
        {:ok, value} -> {:halt, {:ok, value}}
        :error -> {:cont, :error}
      end
    end)
  end

  @doc "The truthiness rule, stated once."
  @spec truthy?(term()) :: boolean()
  def truthy?(false), do: false
  def truthy?(nil), do: false
  def truthy?(0), do: false
  def truthy?(""), do: false
  def truthy?([]), do: false
  def truthy?(_), do: true

  defp apply_inner(value, :raw), do: {:ok, value}
  defp apply_inner(value, nil), do: {:ok, value}
  defp apply_inner(value, spec) when is_binary(value), do: decode(value, spec)
  defp apply_inner(value, {:truthy, _, _} = spec), do: decode(value, spec)
  defp apply_inner(value, {:enum, mapping}), do: decode(value, {:enum_value, mapping})
  defp apply_inner(value, _spec), do: {:ok, value}

  defp get_in_safe(map, []), do: {:ok, map}

  defp get_in_safe(map, [key | rest]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> get_in_safe(value, rest)
      :error -> :error
    end
  end

  defp get_in_safe(_other, _path), do: :error
end
