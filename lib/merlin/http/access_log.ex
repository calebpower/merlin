defmodule Merlin.HTTP.AccessLog do
  @moduledoc """
  Request logging that cannot leak a credential.

  `api.py:31` did `logger.info(data)` on the parsed `/snitch` body -- and the
  API key travels *in that body*, as `challenge`. Every request the phone made
  wrote a live credential to the log at INFO, where `archive_logs.sh` then
  rsynced it to a workstation and kept it.

  Preventing a recurrence is structural rather than a matter of care:

    * this is the only logging plug in the pipeline, and it can see method,
      path, status, duration and remote IP because that is all it is given;
    * `Plug.Logger` and `Plug.Debugger` are not used on the public listener in
      any environment -- `Plug.Debugger` renders params into an error page; and
    * a tier 4 test captures the log during a real request and asserts the key
      does not appear in it.

  The query string is dropped as well. Nothing here uses one, and a future
  endpoint that accepts a token as a parameter should not be able to start
  leaking it by accident.
  """

  @behaviour Plug

  require Logger

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    started = System.monotonic_time()

    Plug.Conn.register_before_send(conn, fn conn ->
      duration = System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)

      Logger.info(fn ->
        "#{conn.method} #{conn.request_path} #{conn.status} #{duration}ms #{peer(conn)}"
      end)

      conn
    end)
  end

  defp peer(conn) do
    case conn.remote_ip do
      nil -> "-"
      ip -> ip |> :inet.ntoa() |> to_string()
    end
  rescue
    _ -> "-"
  end
end
