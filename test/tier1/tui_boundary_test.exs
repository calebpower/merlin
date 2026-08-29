defmodule Merlin.TUIBoundaryTest do
  @moduledoc """
  Tier 1: the client may not read the daemon's state directly.

  A TUI client boots with `--boot start_clean`, which LOADS every `Merlin.*`
  module but starts no application. On the client, therefore:

    * `Merlin.Config.dry_run?()` reads an empty config and answers `false`;
    * `Merlin.World.fetch/1` raises on an ETS table that does not exist.

  The first is the dangerous one. A view that called it would paint LIVE while
  the daemon was in dry run, and an operator who believed they were only asking
  questions would command a house. Nothing about that failure is visible -- the
  banner would be confident and wrong.

  So the rule is enforced mechanically rather than remembered: only
  `Merlin.TUI.Remote` may reach the daemon. This reads the compiled beams,
  which is the same instinct as the tier 3 checks on config -- a rule nobody
  can forget beats a rule everybody knows.

  ## Two rules, because there are two ways to reach

  A **direct call** -- `Merlin.Config.dry_run?()` -- is the dangerous one. On a
  client it does not fail; it answers `false`, and the banner is then confident
  and wrong.

  An **`:erpc`** is safe by construction: it asks the daemon, which has the
  state. But it is still I/O, and a view that performs I/O is no longer a pure
  function of its inputs, so it belongs behind the same door.

  The imports chunk records the first and not the second: `:erpc.call(node,
  Merlin.Config, ...)` passes the module as an ARGUMENT, so it is data rather
  than a call target and no import of `Merlin.Config` is recorded. That is why
  there are two assertions rather than one -- and why the first test written
  here, which assumed `Remote` would show direct imports of the daemon
  modules, was asserting something untrue.
  """

  use ExUnit.Case, async: true

  @moduletag :tier1

  # Modules whose answers are meaningless on a client. Not a stylistic list:
  # each of these either lies or raises when the application is not running.
  @daemon_only [
    Merlin.World,
    Merlin.Config,
    Merlin.Groups,
    Merlin.Rules.Engine,
    Merlin.Settle,
    Merlin.Control,
    Merlin.Tap
  ]

  @allowed [Merlin.TUI.Remote]

  test "no TUI module except Remote reaches for daemon state" do
    offenders =
      for module <- tui_modules(),
          module not in @allowed,
          reached = daemon_calls(module),
          reached != [],
          do: {module, reached}

    assert offenders == [],
           """
           These modules reach daemon state directly:

           #{Enum.map_join(offenders, "\n", fn {m, c} -> "  #{inspect(m)} -> #{inspect(c)}" end)}

           On a client that state is absent, so the call does not fail -- it
           answers wrongly. Route it through Merlin.TUI.Remote.
           """
  end

  test "no TUI module except Remote performs an :erpc" do
    # The other half. A view that reaches the daemon directly is no longer a
    # pure function of its inputs, even when the answer it gets is correct.
    offenders =
      for module <- tui_modules(),
          module not in @allowed,
          :erpc in imports(module),
          do: module

    assert offenders == [],
           "these modules talk to the daemon themselves: #{inspect(offenders)}"
  end

  test "and Remote itself does talk to the daemon" do
    # The control for the assertion above. Without it, an @allowed list that
    # had drifted to cover every module would satisfy it and prove nothing.
    #
    # Asserted on :erpc rather than on direct imports, which is what the first
    # version of this test got wrong: Remote passes the daemon module as an
    # ARGUMENT to :erpc.call/5, so it never imports it and the imports chunk
    # has nothing to show.
    assert :erpc in imports(Merlin.TUI.Remote),
           "Remote is supposed to be the module that talks to the daemon"
  end

  test "the detector actually detects" do
    # A second control, aimed at the detector rather than the list. Merlin.Tap
    # is daemon-side and unquestionably touches this state; if daemon_calls/1
    # cannot see that, it cannot see anything.
    assert daemon_calls(Merlin.Tap) != []
  end

  defp tui_modules do
    {:ok, modules} = :application.get_key(:merlin, :modules)

    Enum.filter(modules, fn module ->
      module |> Atom.to_string() |> String.starts_with?("Elixir.Merlin.TUI")
    end)
  end

  # Imports, from the beam's own chunk. Reads what the compiler recorded rather
  # than the source, so a call built some other way is still caught.
  defp daemon_calls(module) do
    module |> imports() |> Enum.filter(&(&1 in @daemon_only))
  end

  # Every module this one calls directly, from the beam's own chunk. Reads what
  # the compiler recorded rather than the source, so a call written some other
  # way is still seen -- but note it records call TARGETS, so a module passed
  # as an argument to :erpc is invisible here by design.
  defp imports(module) do
    case :code.which(module) do
      path when is_list(path) ->
        {:ok, {^module, [imports: imports]}} = :beam_lib.chunks(path, [:imports])
        imports |> Enum.map(fn {m, _f, _a} -> m end) |> Enum.uniq()

      _ ->
        []
    end
  end
end
