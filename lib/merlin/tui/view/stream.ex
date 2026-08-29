defmodule Merlin.TUI.View.Stream do
  @moduledoc """
  What just happened, newest first.

  The only place an `%Merlin.Event{}` is ever visible. Events are never stored
  -- no value, no identity beyond a path -- so a button press that did nothing
  is unobservable the instant after it happens, everywhere except here.

  Effects show their *outcome*, not merely that they were decided. During a
  dry-run soak the difference between "merlin would have turned the lamps off"
  and "merlin turned the lamps off" is the entire point, and a stream that
  showed only the decision would read identically in both cases.
  """

  alias Merlin.TUI.{Buffer, Scene}

  @kind_w 6
  @outcome_w 9

  @spec render(Scene.t(), map(), {non_neg_integer(), non_neg_integer()}) :: Buffer.t()
  def render(%Scene{} = scene, session, {w, h}) do
    items = filtered(scene, session[:filter])
    rows = max(h - 1, 0)
    selected = session[:selected] || 0
    scroll = Merlin.TUI.View.Facts.scroll_for(selected, session[:scroll] || 0, rows)

    Buffer.new(w, h)
    |> Buffer.write(0, 0, header(items, session[:filter]), [:bright])
    |> body(items, selected, scroll, rows, w)
  end

  defp header([], nil), do: "nothing yet -- this shows what happens from now on"
  defp header([], _filter), do: "nothing matching"
  defp header(items, nil), do: "#{length(items)} recent"
  defp header(items, filter), do: "#{length(items)} recent matching #{inspect(filter)}"

  defp filtered(%Scene{stream: stream}, blank) when blank in [nil, ""], do: stream

  defp filtered(%Scene{stream: stream}, filter) do
    needle = String.downcase(filter)
    Enum.filter(stream, &String.contains?(String.downcase(line(&1)), needle))
  end

  defp body(buffer, items, selected, scroll, rows, w) do
    items
    |> Enum.slice(scroll, rows)
    |> Enum.with_index(scroll)
    |> Enum.reduce(buffer, fn {item, index}, acc ->
      style = if index == selected, do: [:reverse], else: style(item)
      Buffer.write(acc, 0, 1 + index - scroll, Buffer.fit(line(item), w), style)
    end)
  end

  @doc "One item as a line. Public so the tier 9 invariant can read a frame back."
  @spec line(Scene.stream_item()) :: binary()
  def line({:change, c}) do
    Buffer.fit("fact", @kind_w) <>
      " " <>
      Buffer.fit("", @outcome_w) <>
      " " <>
      Merlin.Path.to_string(c.path) <>
      "  " <> Scene.value(c.old) <> " -> " <> Scene.value(c.new)
  end

  def line({:event, e}) do
    Buffer.fit("event", @kind_w) <>
      " " <>
      Buffer.fit("", @outcome_w) <>
      " " <> Merlin.Path.to_string(e.path) <> "  " <> Scene.value(e.payload)
  end

  def line({:effect, r}) do
    Buffer.fit("effect", @kind_w) <>
      " " <>
      Buffer.fit(outcome(r.outcome), @outcome_w) <>
      " " <> Merlin.Effects.describe(r.effect) <> source(r.source)
  end

  def line({:dropped, n}), do: Buffer.fit("--", @kind_w) <> " #{n} dropped"

  defp outcome(:performed), do: "did"
  defp outcome(:dry_run), do: "dry-run"
  defp outcome({:held, _ms}), do: "held"
  defp outcome({:failed, _}), do: "FAILED"

  defp source(nil), do: ""
  defp source({:rule, id}), do: " (#{id})"
  defp source({:operator, who}), do: " (operator #{who})"
  defp source(other), do: " (#{inspect(other)})"

  defp style({:effect, %{outcome: {:failed, _}}}), do: [:red]
  defp style({:effect, %{outcome: :performed}}), do: [:green]
  defp style({:effect, %{outcome: {:held, _}}}), do: [:yellow]
  defp style({:dropped, _}), do: [:yellow]
  defp style({:event, _}), do: [:cyan]
  defp style(_), do: []
end
