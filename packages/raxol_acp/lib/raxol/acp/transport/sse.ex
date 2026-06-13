defmodule Raxol.ACP.Transport.SSE do
  @moduledoc """
  Real `Raxol.ACP.Transport` against the Virtuals ACP Server-Sent
  Events stream at `{server_url}/chats/stream`.

  ## Architecture

  `connect/2` spawns a `Task` that opens an HTTP GET to the SSE
  endpoint via `Req` with a streaming `:into` callback. The callback
  parses SSE frames line-by-line and forwards each completed event
  to the configured owner pid as `{:transport, entry_map}`.

  The Task's pid is stashed in the transport's config so
  `disconnect/1` can kill it.

  ## SSE frame format

  Standard EventSource. Lines separated by `\\n`; an empty line ends
  the event. Recognised fields:

  - `data:` -- accumulated as the event body
  - `event:` -- the SSE event type (the v2 server uses `entry`)
  - `id:` -- ignored

  Anything else is ignored (no `retry:` handling -- we reconnect
  externally if the stream drops).

  ## Construction

      transport =
        Raxol.ACP.Transport.SSE.new(
          auth: my_auth_pid,
          server_url: "https://api-dev.acp.virtuals.io",
          supported_chain_ids: [8453]
        )

  Then in your agent:

      Raxol.ACP.Transport.connect(transport, %{
        owner: self(),
        chain_ids: [8453],
        wallet_address: "0x..."
      })
  """

  @behaviour Raxol.ACP.Transport

  alias Raxol.ACP.Auth

  @doc """
  Build a transport.

  ## Required

  - `:auth` -- `pid()` or name of a `Raxol.ACP.Auth` process.
  - `:server_url` -- e.g. `https://api-dev.acp.virtuals.io`.

  ## Optional

  - `:supported_chain_ids` -- defaults to `[8453]`. Sent as the
    `x-supported-chains` header.
  - `:req_options` -- extra options threaded into Req (for testing).
  """
  @spec new(keyword()) :: Raxol.ACP.Transport.t()
  def new(opts) do
    table = :ets.new(:raxol_acp_transport_sse, [:set, :public])
    :ets.insert(table, {:stream_task, nil})

    config = %{
      auth: Keyword.fetch!(opts, :auth),
      server_url: opts |> Keyword.fetch!(:server_url) |> String.trim_trailing("/"),
      supported_chain_ids: Keyword.get(opts, :supported_chain_ids, [8453]),
      req_options: Keyword.get(opts, :req_options, []),
      table: table
    }

    %{adapter: __MODULE__, config: config}
  end

  # -- Transport behaviour --

  @impl Raxol.ACP.Transport
  def connect(%{config: cfg}, %{owner: owner}) do
    case Auth.token(cfg.auth) do
      {:ok, token} ->
        url = cfg.server_url <> "/chats/stream"

        headers = [
          {"authorization", "Bearer " <> token},
          {"accept", "text/event-stream"},
          {"x-supported-chains", Jason.encode!(cfg.supported_chain_ids)}
        ]

        task =
          Task.async(fn ->
            stream_loop(owner, url, headers, cfg.req_options)
          end)

        :ets.insert(cfg.table, {:stream_task, task})
        :ok

      err ->
        err
    end
  end

  @impl Raxol.ACP.Transport
  def disconnect(%{config: cfg}) do
    case :ets.lookup(cfg.table, :stream_task) do
      [{:stream_task, nil}] ->
        :ok

      [{:stream_task, %Task{} = task}] ->
        Task.shutdown(task, :brutal_kill)
        :ets.insert(cfg.table, {:stream_task, nil})
        :ok
    end
  end

  @impl Raxol.ACP.Transport
  def get_history(%{config: cfg}, {chain_id, job_id}) do
    case Auth.token(cfg.auth) do
      {:ok, token} ->
        url = cfg.server_url <> "/jobs/#{chain_id}/#{job_id}"

        case Req.get(url: url, headers: [{"authorization", "Bearer " <> token}]) do
          {:ok, %Req.Response{status: 200, body: %{"data" => %{"entries" => entries}}}}
          when is_list(entries) ->
            {:ok, entries}

          {:ok, %Req.Response{status: 200, body: _}} ->
            {:ok, []}

          {:ok, %Req.Response{status: 404}} ->
            {:ok, []}

          {:ok, %Req.Response{status: status, body: body}} ->
            {:error, {:http_status, status, body}}

          err ->
            err
        end

      err ->
        err
    end
  end

  @impl Raxol.ACP.Transport
  def post_message(%{config: cfg}, {chain_id, job_id}, content, content_type) do
    case Auth.token(cfg.auth) do
      {:ok, token} ->
        url = cfg.server_url <> "/jobs/#{chain_id}/#{job_id}/messages"

        body = %{"content" => content, "contentType" => content_type}

        case Req.post(url: url, headers: [{"authorization", "Bearer " <> token}], json: body) do
          {:ok, %Req.Response{status: status}} when status in 200..299 ->
            :ok

          {:ok, %Req.Response{status: status, body: body}} ->
            {:error, {:http_status, status, body}}

          err ->
            err
        end

      err ->
        err
    end
  end

  @impl Raxol.ACP.Transport
  def send_message(transport, key, content, content_type) do
    # The v2 SDK distinguishes "stream send" from "REST post"; for our
    # purposes both go through POST /messages and the stream picks up the
    # echoed entry via SSE. So we delegate.
    post_message(transport, key, content, content_type)
  end

  # -- SSE streaming --

  defp stream_loop(owner, url, headers, req_options) do
    opts =
      [
        url: url,
        method: :get,
        headers: headers,
        into: fn {:data, data}, {req, resp} ->
          handle_chunk(owner, data)
          {:cont, {req, resp}}
        end
      ] ++ req_options

    # Req blocks until the stream closes; if the server closes, we exit
    # normally. The caller (Agent) is responsible for reconnecting.
    try do
      Req.request(opts)
    catch
      _, _ -> :ok
    end
  end

  defp handle_chunk(owner, data) do
    # Buffer partials in the process dictionary; this task is short-lived
    # per connection so there's no leakage.
    buffer = Process.get(:sse_buffer, "")
    accumulated = buffer <> data

    {frames, rest} = Raxol.ACP.Transport.SSE.Parser.split_frames(accumulated)
    Process.put(:sse_buffer, rest)

    for frame <- frames do
      case Raxol.ACP.Transport.SSE.Parser.parse_frame(frame) do
        {:ok, entry} -> send(owner, {:transport, entry})
        {:error, _} -> :ok
      end
    end
  end
end
