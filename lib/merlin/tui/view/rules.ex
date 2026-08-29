defmodule Merlin.TUI.View.Rules do
  @moduledoc """
  Every rule, both kinds, and what each is doing.

  Machines are here because they were missing everywhere else. `/rules.json`
  filtered to stateless rules, so the intruder latch, the printer sequence and
  the A/C load shed -- the whole stateful half of the automation -- were absent
  from the endpoint documented as the first place to look when a rule is not
  firing.

  A machine shows its current state, because that is the question. A rule shows
  its guard, because that is where the answer usually is.
  """

  alias Merlin.TUI.{Buffer, Scene}

  @id_w 24
  @kind_w 8
  @state_w 10

  @spec render(Scene.t(), map(), {non_neg_integer(), non_neg_integer()}) :: Buffer.t()
  def render(%Scene{} = scene, session, {w, h}) do
    rules = filtered(scene, session[:filter])
    rows = max(h - 2, 0)
    selected = session[:selected] || 0
    scroll = Merlin.TUI.View.Facts.scroll_for(selected, session[:scroll] || 0, rows)

    Buffer.new(w, h)
    |> Buffer.write(0, 0, "#{length(rules)} rules", [:bright])
    |> Buffer.write(0, 1, columns(w), [:faint])
    |> body(scene, rules, selected, scroll, rows, w)
  end

  defp columns(w) do
    Enum.join(
      [
        Buffer.fit("RULE", @id_w),
        Buffer.fit("KIND", @kind_w),
        Buffer.fit("STATE", @state_w),
        Buffer.fit("GUARD", guard_width(w))
      ],
      " "
    )
  end

  defp filtered(%Scene{rules: rules}, blank) when blank in [nil, ""], do: rules

  defp filtered(%Scene{rules: rules}, filter) do
    needle = String.downcase(filter)
    Enum.filter(rules, &String.contains?(String.downcase(to_string(&1.id)), needle))
  end

  defp body(buffer, scene, rules, selected, scroll, rows, w) do
    rules
    |> Enum.slice(scroll, rows)
    |> Enum.with_index(scroll)
    |> Enum.reduce(buffer, fn {rule, index}, acc ->
      style = if index == selected, do: [:reverse], else: style(rule)
      Buffer.write(acc, 0, 2 + index - scroll, row(scene, rule, w), style)
    end)
  end

  defp row(scene, rule, w) do
    Enum.join(
      [
        Buffer.fit(to_string(rule.id), @id_w),
        Buffer.fit(kind(rule), @kind_w),
        Buffer.fit(state(scene, rule), @state_w),
        Buffer.fit(guard(rule), guard_width(w))
      ],
      " "
    )
  end

  defp kind(%Merlin.Machine{}), do: "machine"
  defp kind(_), do: "rule"

  # The live state if the daemon reported one, otherwise the declared initial.
  # Falling back is honest -- it is what the machine would be in -- and better
  # than a blank column that reads as "no idea".
  defp state(%Scene{states: states}, %Merlin.Machine{} = m),
    do: to_string(Map.get(states, m.id, m.initial))

  defp state(_scene, _rule), do: ""

  defp guard(%Merlin.Rule{guard: nil}), do: ""
  defp guard(%Merlin.Rule{guard: g}), do: g.source
  defp guard(%Merlin.Machine{}), do: "(per clause)"

  defp style(%{enabled: false}), do: [:faint]
  defp style(_), do: []

  defp guard_width(w), do: max(w - @id_w - @kind_w - @state_w - 3, 8)
end
