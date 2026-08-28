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

  get "/rules.json" do
    rules =
      Merlin.Rules.Engine.rules()
      |> Enum.map(fn r ->
        %{
          id: r.id,
          desc: r.desc,
          triggers: inspect(r.triggers),
          guard: r.guard && r.guard.source,
          watches: Enum.map(r.watches, &Path.to_string/1),
          watch_events: Enum.map(r.watch_events, &Path.to_string/1),
          # A rule triggering on a group has no watches of its own. Omitting
          # this would render it as a rule subscribed to nothing, which is
          # exactly the diagnosis this endpoint exists to give.
          watch_groups: r.watch_groups,
          watch_group_members:
            Enum.flat_map(r.watch_groups, fn g ->
              Enum.map(Merlin.Groups.members(g), &Path.to_string/1)
            end)
        }
      end)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{count: length(rules), rules: rules}))
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
