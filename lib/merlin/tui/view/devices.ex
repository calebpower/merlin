defmodule Merlin.TUI.View.Devices do
  @moduledoc """
  Groups, their members, and what those members currently say.

  A group is the only thing merlin can be told to command, so this is the pane
  where control lives. It shows the members' *facts* rather than a single
  aggregate state, because "the living room lamps" is two bulbs and they can
  disagree -- and the toggle rule's whole asymmetry (off only when both are on)
  is invisible if you collapse them to one row.

  Groups with no `set_topic` are shown and marked. They exist to be read --
  `:exterior_doors` names which doors alarm -- and hiding them would leave an
  operator wondering where a group named in a rule had gone.
  """

  alias Merlin.TUI.{Buffer, Scene}

  @group_w 22
  @value_w 12

  @spec render(Scene.t(), map(), {non_neg_integer(), non_neg_integer()}) :: Buffer.t()
  def render(%Scene{} = scene, session, {w, h}) do
    groups = groups(scene, session[:filter])
    rows = max(h - 1, 0)
    selected = session[:selected] || 0
    scroll = Merlin.TUI.View.Facts.scroll_for(selected, session[:scroll] || 0, rows)

    Buffer.new(w, h)
    |> Buffer.write(0, 0, "#{length(groups)} groups", [:bright])
    |> body(scene, groups, selected, scroll, rows, w)
  end

  defp groups(%Scene{groups: groups}, blank) when blank in [nil, ""],
    do: groups |> Map.values() |> Enum.sort_by(& &1.id)

  defp groups(%Scene{groups: groups}, filter) do
    needle = String.downcase(filter)

    groups
    |> Map.values()
    |> Enum.filter(&String.contains?(String.downcase(to_string(&1.id)), needle))
    |> Enum.sort_by(& &1.id)
  end

  defp body(buffer, scene, groups, selected, scroll, rows, w) do
    groups
    |> Enum.slice(scroll, rows)
    |> Enum.with_index(scroll)
    |> Enum.reduce(buffer, fn {group, index}, acc ->
      style = if index == selected, do: [:reverse], else: style(group)
      Buffer.write(acc, 0, 1 + index - scroll, row(scene, group, w), style)
    end)
  end

  defp row(scene, group, w) do
    Enum.join(
      [
        Buffer.fit(to_string(group.id), @group_w),
        Buffer.fit(commandable(group), 12),
        Buffer.fit(members(scene, group), max(w - @group_w - 14, 8))
      ],
      " "
    )
  end

  defp commandable(%{set_topic: topic}) when is_binary(topic), do: "commandable"
  defp commandable(_), do: "read-only"

  defp members(scene, group) do
    group
    |> Map.get(:members, [])
    |> Enum.map_join("  ", fn path ->
      value =
        scene.facts
        |> Enum.find(&(&1.path == path))
        |> case do
          nil -> "?"
          fact -> Scene.value(fact.value)
        end

      leaf(path) <> "=" <> Buffer.fit(value, min(String.length(value), @value_w))
    end)
  end

  # The last segment that is not an attribute name, so two lamps read as
  # "one=:on  two=:off" rather than repeating their whole paths.
  defp leaf(path) do
    path |> Enum.slice(1..-2//1) |> Enum.map_join(".", &to_string/1)
  end

  defp style(%{set_topic: topic}) when is_binary(topic), do: []
  defp style(_), do: [:faint]
end
