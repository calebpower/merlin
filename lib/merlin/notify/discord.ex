defmodule Merlin.Notify.Discord do
  @moduledoc """
  Discord webhook notifications.

  ## Bug 4

  `alerts.py` checked `if response.status != 200` and logged an error
  otherwise. Discord webhooks answer **204 No Content** on success, so every
  successful alert that daemon ever sent also wrote an error line to the log.

  That is worse than cosmetic. A log where success looks like failure trains
  you to ignore the error lines, which is precisely when a real failure
  becomes invisible. Any 2xx is success here.

  ## Retries

  Bounded, with backoff, and only for the failures worth retrying: transport
  errors, 5xx, and 429. A 404 is permanent -- Discord revokes a webhook by
  deleting it -- so it is worth saying loudly once rather than sixty times.

  ## Never raises

  A notifier that crashes its caller turns "the alert did not send" into "the
  rule did not run", which is a strictly worse failure. Every path returns
  `:ok` or `{:error, reason}`.
  """

  require Logger

  alias Merlin.Secrets

  @max_attempts 3
  @base_backoff_ms 500

  @doc """
  Send `message` to the configured webhook.

  The webhook URL is a secret reference by default, so it never appears in
  `merlin.exs` and never reaches a log through an inspected struct.
  """
  @spec send(binary(), keyword()) :: :ok | {:error, term()}
  def send(message, opts \\ []) when is_binary(message) do
    case Secrets.resolve(Keyword.get(opts, :webhook, {:secret, :discord_webhook})) do
      {:ok, url} when is_binary(url) -> attempt(url, message, opts, 1)
      {:ok, _} -> {:error, :no_webhook_configured}
      {:error, reason} -> {:error, reason}
    end
  end

  defp attempt(url, message, opts, tries) do
    req_options =
      [url: url, json: %{content: message}, receive_timeout: 5_000, retry: false]
      |> Keyword.merge(
        Keyword.get(opts, :req_options, Application.get_env(:merlin, :req_options, []))
      )

    case Req.post(req_options) do
      # ANY 2xx. Discord answers 204; demanding exactly 200 is bug 4.
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: 404}} ->
        Logger.error(
          "discord webhook returned 404 -- it has been deleted; alerts are going nowhere"
        )

        {:error, :webhook_deleted}

      {:ok, %{status: status}} when status == 429 or status in 500..599 ->
        retry_or_give_up(url, message, opts, tries, {:http_status, status})

      {:ok, %{status: status}} ->
        Logger.warning("discord rejected the message with #{status}")
        {:error, {:http_status, status}}

      {:error, reason} ->
        retry_or_give_up(url, message, opts, tries, {:transport, reason})
    end
  end

  defp retry_or_give_up(_url, _message, _opts, tries, reason) when tries >= @max_attempts do
    Logger.warning("discord notification failed after #{tries} attempts: #{inspect(reason)}")
    {:error, reason}
  end

  defp retry_or_give_up(url, message, opts, tries, _reason) do
    Process.sleep(@base_backoff_ms * tries)
    attempt(url, message, opts, tries + 1)
  end

  @doc "Attempts made before giving up. Exposed for tests."
  def max_attempts, do: @max_attempts
end
