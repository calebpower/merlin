defmodule Merlin.HTTP.LocalRouter do
  @moduledoc """
  The loopback listener: introspection, and later the dashboard.

  Bound to 127.0.0.1 and kept apart from `Merlin.HTTP.PublicRouter` because
  these endpoints answer questions like "is anyone home", "where is the
  vehicle" and "which doors are open". That is a wildly different exposure
  profile from an endpoint a phone posts to over the internet, and putting
  them behind one listener would mean the weaker requirement wins.

  `/facts.json` is the debugging tool for the cutover: it is how you check what
  the daemon actually believes, rather than inferring it from behaviour.
  """

  use Plug.Router

  alias Merlin.{Fact, Path, World}

  plug(Merlin.HTTP.AccessLog)
  plug(:match)
  plug(:dispatch)

  get "/facts.json" do
    conn = fetch_query_params(conn)
    prefix = parse_prefix(conn)

    facts =
      prefix
      |> World.dump()
      |> Enum.map(fn %Fact{} = f ->
        %{
          path: Path.to_string(f.path),
          value: inspect(f.value),
          age_ms: Fact.age(f),
          stale: Fact.stale?(f),
          source: inspect(f.source),
          seq: f.seq
        }
      end)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{count: length(facts), facts: facts}))
  end

  # Every rule, both kinds.
  #
  # This read Merlin.Rules.Engine.rules/0, which filters to %Rule{} -- so the
  # entire stateful half of the automation was absent from the one endpoint the
  # README calls "the first place to look when a rule is not firing". The
  # intruder latch, the printer sequence and the A/C load shed are all
  # machines, and all three were invisible here.
  get "/rules.json" do
    rules = Enum.map(Merlin.Config.rules(), &render_rule/1)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{count: length(rules), rules: rules}))
  end

  defp render_rule(%Merlin.Rule{} = r) do
    %{
      id: r.id,
      kind: "rule",
      desc: r.desc,
      enabled: r.enabled,
      triggers: inspect(r.triggers),
      guard: r.guard && r.guard.source,
      actions: inspect(r.actions)
    }
    |> Map.merge(watches(r))
  end

  defp render_rule(%Merlin.Machine{} = m) do
    %{
      id: m.id,
      kind: "machine",
      desc: m.desc,
      enabled: m.enabled,
      persist: m.persist,
      initial: m.initial,
      # What it is doing NOW, which is the question actually being asked. Falls
      # back to the declared initial state if no process answers, rather than
      # failing the whole endpoint because one machine is restarting.
      state: current_state(m),
      states:
        Map.new(m.states, fn {name, clauses} ->
          {name, Enum.map(clauses, &render_clause/1)}
        end)
    }
    |> Map.merge(watches(m))
  end

  defp render_clause(%Merlin.Machine.Clause{} = c) do
    %{
      trigger: inspect(c.trigger),
      guard: c.guard && c.guard.source,
      goto: c.goto,
      sets: inspect(c.sets),
      actions: inspect(c.actions),
      postpone: c.postpone
    }
  end

  # A rule triggering on a group has no watches of its own. Omitting this would
  # render it as subscribed to nothing, which is exactly the diagnosis this
  # endpoint exists to give.
  defp watches(r) do
    %{
      watches: Enum.map(r.watches, &Path.to_string/1),
      watch_events: Enum.map(r.watch_events, &Path.to_string/1),
      watch_groups: r.watch_groups,
      watch_group_members:
        Enum.flat_map(r.watch_groups, fn g ->
          Enum.map(Merlin.Groups.members(g), &Path.to_string/1)
        end)
    }
  end

  defp current_state(%Merlin.Machine{} = m) do
    Merlin.Machine.Server.state(m.id)
  catch
    :exit, _ -> m.initial
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp parse_prefix(conn) do
    case conn.query_params["prefix"] do
      nil -> []
      "" -> []
      p -> Path.parse(p)
    end
  end
end
