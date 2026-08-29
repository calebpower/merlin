defmodule Merlin.TUI.View.Facts do
  @moduledoc """
  Everything merlin believes, one fact per row.

  Four columns, in the order the questions get asked: what is it, what does it
  say, when did it last say anything, and who told it.

  Age is the column that earns its place. `/facts.json` reports a value with
  nothing about its provenance in time, so a tracker that went dark four hours
  ago and one reporting every thirty seconds look identical -- which is exactly
  the confusion the certainty window exists to resolve.

  A stale fact is marked, never hidden. Hiding it would be the daemon deciding
  what the operator is allowed to know, and the value may well be true; it is
  simply old enough that nothing should be decided on it.
  """

  alias Merlin.TUI.{Buffer, Scene}

  # Path takes whatever is left; the rest are fixed so columns line up between
  # frames and the eye can track a row down the screen.
  @value_w 14
  @age_w 6
  @source_w 12

  @doc """
  Render into a `{width, height}` rect.

  `selected` and `scroll` come from the session, not the scene, so two
  attached sessions can look at different parts of the same house.
  """
  @spec render(Scene.t(), map(), {non_neg_integer(), non_neg_integer()}) :: Buffer.t()
  def render(%Scene{} = scene, session, {w, h}) do
    facts = Scene.facts(scene, session[:filter])
    rows = max(h - 2, 0)
    selected = session[:selected] || 0
    scroll = scroll_for(selected, session[:scroll] || 0, rows)

    Buffer.new(w, h)
    |> header(w, facts, session[:filter])
    |> body(scene, facts, selected, scroll, rows, w)
  end

  @doc "The first visible row, given where the selection is. Pure, and the session keeps it."
  @spec scroll_for(non_neg_integer(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def scroll_for(selected, scroll, rows) when rows > 0 do
    cond do
      selected < scroll -> selected
      selected >= scroll + rows -> selected - rows + 1
      true -> scroll
    end
  end

  def scroll_for(_selected, _scroll, _rows), do: 0

  defp header(buffer, w, facts, filter) do
    counted =
      case filter do
        blank when blank in [nil, ""] -> "#{length(facts)} facts"
        text -> "#{length(facts)} facts matching #{inspect(text)}"
      end

    buffer
    |> Buffer.write(0, 0, counted, [:bright])
    |> Buffer.write(0, 1, columns(path_width(w)), [:faint])
  end

  defp columns(path_w) do
    Enum.join(
      [
        Buffer.fit("PATH", path_w),
        Buffer.fit("VALUE", @value_w),
        Buffer.fit("AGE", @age_w),
        Buffer.fit("SOURCE", @source_w)
      ],
      " "
    )
  end

  defp body(buffer, scene, facts, selected, scroll, rows, w) do
    path_w = path_width(w)

    facts
    |> Enum.slice(scroll, rows)
    |> Enum.with_index(scroll)
    |> Enum.reduce(buffer, fn {fact, index}, acc ->
      Buffer.write(
        acc,
        0,
        2 + index - scroll,
        row(scene, fact, path_w),
        style(scene, fact, index == selected)
      )
    end)
  end

  defp row(scene, fact, path_w) do
    Enum.join(
      [
        Buffer.fit(Merlin.Path.to_string(fact.path), path_w),
        Buffer.fit(Scene.value(fact.value), @value_w),
        Buffer.fit(age(scene, fact), @age_w),
        Buffer.fit(source(fact.source), @source_w)
      ],
      " "
    )
  end

  # The mark goes in the age column, because age is what is wrong with a stale
  # fact -- not its value.
  defp age(scene, fact) do
    rendered = Scene.age(scene, fact)
    if Scene.stale?(scene, fact), do: rendered <> "!", else: rendered
  end

  defp style(scene, fact, selected?) do
    cond do
      selected? -> [:reverse]
      Scene.stale?(scene, fact) -> [:faint]
      fact.value == :unknown -> [:faint]
      true -> []
    end
  end

  defp source({:adapter, module}), do: module |> Module.split() |> List.last()
  defp source({:rule, id}), do: "rule #{id}"
  defp source({:machine, id}), do: "machine #{id}"
  defp source({:derive, id}), do: "derive #{id}"
  defp source({:operator, who}), do: "op #{who}"
  defp source({:http, _key}), do: "http"
  defp source({:snapshot, _}), do: "snapshot"
  defp source(nil), do: ""
  defp source(other), do: inspect(other)

  defp path_width(w), do: max(w - @value_w - @age_w - @source_w - 3, 8)
end
