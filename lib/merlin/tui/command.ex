defmodule Merlin.TUI.Command do
  @moduledoc """
  The command line: a small vocabulary, and an expression escape hatch.

  Parsing is pure and total. It never touches the daemon, never resolves a
  group, never evaluates anything -- it turns a line of text into one of four
  shapes and hands it back:

    * `{:control, command}` -- something that changes the house. Goes to
      `Merlin.Control.prepare/3`, is described back to the operator, and runs
      only on confirmation. Parsing one does not arm it.
    * `{:view, action}`     -- filtering, switching pane, scrolling. Local to
      the session; the daemon never hears about it.
    * `{:expr, source}`     -- evaluate a merlin expression against the world.
    * `{:error, message}`   -- said in words, not a tuple nobody can read.

  Keeping resolution out of here is what makes the whole language testable as a
  pure function, and it is why a typo cannot actuate anything: the earliest a
  command can reach the house is after `Control` has resolved it, described it,
  and been given back its token.

  ## `=` is an expression, not an eval

  `= any_eq?(:exterior_doors, :open)` compiles through `Merlin.Expr`, which
  parses without executing and interprets a closed whitelist of eleven
  builtins. It cannot open a file, spawn a process or reach a module.

  That is the whole reason the prefix exists rather than a general eval box: an
  arbitrary-code prompt is `bin/merlind remote` with a nicer font, and that
  already exists and is honest about what it is.

  ## Values are atoms unless quoted

  `set lamps off` means `:off`, because the vocabulary of this house is atoms:
  `:on`, `:home`, `:printing`. A quoted `"off"` is the string. Numbers are
  numbers. Guessing per-value from context would make `set lamps off` and
  `set lamps "off"` mean the same thing until the day one of them did not.
  """

  alias Merlin.{Expr, Path}

  @type action ::
          {:control, Merlin.Control.command()}
          | {:view, view_action()}
          | {:expr, binary()}
          | :quit
          | :help
          | {:error, binary()}

  @type view_action ::
          {:filter, binary()}
          | :clear_filter
          | {:pane, atom()}

  @panes %{
    "facts" => :facts,
    "rules" => :rules,
    "stream" => :stream,
    "devices" => :devices
  }

  @doc """
  Parse a line. Total: every input produces an action, including a bad one.
  """
  @spec parse(binary()) :: action()
  def parse(line) when is_binary(line) do
    line |> String.trim() |> dispatch()
  end

  defp dispatch(""), do: {:error, ""}

  # The expression prefix is checked before word splitting, so `=` needs no
  # space after it and an expression containing spaces survives intact.
  defp dispatch("=" <> source) do
    source = String.trim(source)

    case Expr.compile(source) do
      {:ok, _compiled} ->
        {:expr, source}

      {:error, reason} ->
        # Refused here, at the keystroke, rather than becoming :unknown later
        # and looking like a house that had nothing to say.
        {:error, "not a valid expression: #{inspect(reason)}"}
    end
  end

  defp dispatch(line) do
    case String.split(line, ~r/\s+/, parts: 3) do
      ["quit"] -> :quit
      ["q"] -> :quit
      ["help"] -> :help
      ["?"] -> :help
      ["set", group, value] -> control_set(group, value)
      ["set" | _] -> {:error, "set <group> <value>, e.g. set living_room_lamps off"}
      ["publish", topic, payload] -> {:control, {:publish, topic, payload}}
      ["publish" | _] -> {:error, "publish <topic> <payload>"}
      ["fact", path, value] -> control_fact(path, value)
      ["fact" | _] -> {:error, "fact <path> <value>, e.g. fact person.cal.zone :home"}
      ["filter", text] -> {:view, {:filter, text}}
      ["filter"] -> {:view, :clear_filter}
      ["pane", name] -> pane(name)
      # Was falling through to unknown/1 and answering `no command "pane"`,
      # which is not true and sends you looking for the right word for a word
      # that was already right.
      ["pane"] -> {:error, "pane <name>. Try: " <> Enum.join(Map.keys(@panes), ", ")}
      [word] -> unknown(word)
      [word | _] -> unknown(word)
    end
  end

  defp control_set(group, value) do
    # A group name that is not already an atom cannot name a configured group,
    # so refusing here is both safe and more useful than minting an atom that
    # is guaranteed not to resolve.
    case existing(group) do
      atom when is_atom(atom) -> {:control, {:set_group, atom, value(value)}}
      _ -> {:error, "no group called #{inspect(group)}"}
    end
  end

  defp control_fact(path, value) do
    # Path.parse/1 returns the segments directly and already resolves each to
    # an EXISTING atom, falling back to a binary -- so a fact path typed at a
    # command line cannot grow the atom table. That decision is already made in
    # the codebase; this follows it rather than making a second one.
    case Path.parse(path) do
      [""] -> {:error, "a fact needs a path, e.g. person.cal.zone"}
      parsed -> {:control, {:set_fact, parsed, value(value)}}
    end
  end

  defp pane(name) do
    case Map.fetch(@panes, name) do
      {:ok, pane} -> {:view, {:pane, pane}}
      :error -> {:error, "no pane #{inspect(name)}. Try: #{Enum.join(Map.keys(@panes), ", ")}"}
    end
  end

  defp unknown(word) do
    {:error, "no command #{inspect(word)}. Try help, or = for an expression."}
  end

  # --- values ---------------------------------------------------------------

  @doc """
  Parse one value the way the configuration language would read it.

  Public because "what does `off` mean" is a question worth being able to ask
  in a test directly, rather than only through a whole command.
  """
  @spec value(binary()) :: term()
  def value(<<?", _::binary>> = quoted) do
    # A quoted value is a string, always. This is the only way to say "the
    # string off" rather than "the atom :off".
    quoted |> String.trim("\"") |> to_string()
  end

  def value(":" <> rest), do: existing(rest)

  def value(raw) do
    cond do
      raw =~ ~r/^-?\d+$/ -> String.to_integer(raw)
      raw =~ ~r/^-?\d+\.\d+$/ -> String.to_float(raw)
      # The vocabulary of a house is atoms. `set lamps off` means :off, and
      # the quoted form is there for the rare value that really is text.
      true -> existing(raw)
    end
  end

  # An EXISTING atom, or the text unchanged. Never String.to_atom/1: the atom
  # table is a finite, un-garbage-collected resource, and a value nothing in
  # this house has ever named is far likelier to be a typo than a new concept.
  #
  # The same rule Merlin.Path.parse/1 already applies to path segments, so a
  # command line and a fact path agree about what a bare word means.
  defp existing(raw) do
    String.to_existing_atom(raw)
  rescue
    ArgumentError -> raw
  end

  @doc "One line of help per command, for the pane that shows it."
  @spec help() :: [{binary(), binary()}]
  def help do
    [
      {"set <group> <value>", "command a group, e.g. set living_room_lamps off"},
      {"publish <topic> <payload>", "publish a raw MQTT message"},
      {"fact <path> <value>", "write a fact by hand"},
      {"= <expression>", "evaluate a merlin expression against the world"},
      {"filter <text>", "narrow the current pane; bare filter clears it"},
      {"pane <name>", "facts, rules, stream or devices"},
      {"help", "this"},
      {"quit", "leave, restoring the terminal"}
    ]
  end

  @doc """
  The verbs, taken from `help/0` rather than listed again.

  A second list would be a second thing to forget: a command added to `help/0`
  and not here would be documented and uncompletable, and one added here and
  not there would complete to something the parser rejects.
  """
  @spec verbs() :: [binary()]
  def verbs, do: Enum.map(help(), fn {form, _does} -> form |> String.split(" ") |> hd() end)

  @doc """
  Complete the word currently being typed.

  Returns `{input, candidates}`. One match completes and adds a space; several
  advance as far as they agree and hand back the list so the caller can show
  it; none leaves the line untouched.

  Completion is a pure function of the line and the scene, which is what makes
  it testable without a terminal or a daemon -- and it is why the candidates
  come from the SCENE. The client has every module loaded and no daemon state,
  so asking `Merlin.Groups` here would offer an empty list of groups on every
  machine except the one nobody runs this on.
  """
  @spec complete(binary(), Merlin.TUI.Scene.t()) :: {binary(), [binary()]}
  def complete(input, scene) when is_binary(input) do
    prefix = last_word(input)

    matches =
      input
      |> candidates(scene)
      |> Enum.uniq()
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.sort()

    case matches do
      [] -> {input, []}
      [one] -> {replace_last(input, prefix, one <> " "), [one]}
      many -> {replace_last(input, prefix, common_prefix(many)), many}
    end
  end

  defp candidates(input, scene) do
    trimmed = String.trim_leading(input)

    if String.starts_with?(trimmed, "=") do
      # Inside an expression the useful thing to finish is a path; the eleven
      # builtins are short enough to type and are listed in the help.
      fact_paths(scene)
    else
      case String.split(trimmed, " ") do
        [_verb_being_typed] -> verbs()
        [verb | rest] -> argument(verb, length(rest), scene)
      end
    end
  end

  defp argument("set", 1, scene), do: group_names(scene)
  defp argument("pane", 1, _scene), do: Map.keys(@panes)
  defp argument("fact", 1, scene), do: fact_paths(scene)
  defp argument("filter", 1, scene), do: fact_paths(scene)
  # A value is whatever the house calls it, so there is nothing honest to
  # offer. Completing to a guess would be worse than completing to nothing.
  defp argument(_verb, _position, _scene), do: []

  defp group_names(scene), do: scene.groups |> Map.keys() |> Enum.map(&to_string/1)

  defp fact_paths(scene), do: Enum.map(scene.facts, &Path.to_string(&1.path))

  # The last space-separated token, which is "" directly after a space -- the
  # case that matters, because that is when the whole candidate list should be
  # offered rather than nothing.
  defp last_word(input), do: input |> String.split(" ") |> List.last() |> Kernel.||("")

  defp replace_last(input, prefix, replacement) do
    String.slice(input, 0, String.length(input) - String.length(prefix)) <> replacement
  end

  defp common_prefix([first | rest]), do: Enum.reduce(rest, first, &common/2)

  defp common(a, b) do
    a
    |> String.graphemes()
    |> Enum.zip(String.graphemes(b))
    |> Enum.take_while(fn {x, y} -> x == y end)
    |> Enum.map_join(fn {x, _y} -> x end)
  end
end
