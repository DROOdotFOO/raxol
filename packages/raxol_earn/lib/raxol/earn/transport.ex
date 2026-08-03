defmodule Raxol.Earn.Transport do
  @moduledoc """
  Behaviour for the chat / event transport between a raxol agent and
  Virtuals's ACP server.

  Mirrors `AcpChatTransport` in `acp-node-v2`. Two implementations are
  expected:

  - `Raxol.Earn.Transport.SSE` -- real Server-Sent Events stream from
    `api.acp.virtuals.io` (production) / `api-dev.acp.virtuals.io`
    (testnet). The default for live deployments.
  - `Raxol.Earn.Transport.Mock` -- in-process implementation for tests.
    Lets a test drive entry deliveries without HTTP.

  ## Lifecycle

      transport |> connect(ctx)        # opens stream; pushes entries to ctx.owner
      transport |> get_history(...)    # one-shot HTTP read of job history
      transport |> post_message(...)   # one-shot HTTP send
      transport |> send_message(...)   # streaming send
      transport |> disconnect()        # closes stream

  The transport never decides job semantics -- it just shuttles
  `JobRoomEntry`-shaped maps. `Raxol.Earn.Agent` is responsible for
  routing each entry into the right `Raxol.Earn.JobSession`.

  ## Entry shape

  Entries arrive as maps with at minimum:

      %{
        "kind" => "system" | "message",
        "chainId" => 8453,
        "jobId" => "123",
        "at" => "2026-06-13T16:00:00Z",
        ... protocol-specific fields ...
      }

  Agent decodes these into the canonical
  `Raxol.Earn.JobSession.entry()` shape via `Raxol.Earn.Event.decode_type/1`.
  """

  @type t :: %{
          required(:adapter) => module(),
          optional(:config) => map()
        }

  @type context :: %{
          owner: pid(),
          chain_ids: [pos_integer()],
          wallet_address: String.t()
        }

  @type entry :: map()

  @type job_key :: {pos_integer(), String.t() | non_neg_integer()}

  @callback connect(t(), context()) :: :ok | {:error, term()}
  @callback disconnect(t()) :: :ok

  @callback get_history(t(), job_key()) :: {:ok, [entry()]} | {:error, term()}

  @callback post_message(
              t(),
              job_key(),
              content :: String.t(),
              content_type :: String.t()
            ) :: :ok | {:error, term()}

  @callback send_message(
              t(),
              job_key(),
              content :: String.t(),
              content_type :: String.t()
            ) :: :ok | {:error, term()}

  # -- Dispatch helpers --

  @spec connect(t(), context()) :: :ok | {:error, term()}
  def connect(transport, ctx), do: transport.adapter.connect(transport, ctx)

  @spec disconnect(t()) :: :ok
  def disconnect(transport), do: transport.adapter.disconnect(transport)

  @spec get_history(t(), job_key()) :: {:ok, [entry()]} | {:error, term()}
  def get_history(transport, key), do: transport.adapter.get_history(transport, key)

  @spec post_message(t(), job_key(), String.t(), String.t()) :: :ok | {:error, term()}
  def post_message(transport, key, content, content_type \\ "text") do
    transport.adapter.post_message(transport, key, content, content_type)
  end

  @spec send_message(t(), job_key(), String.t(), String.t()) :: :ok | {:error, term()}
  def send_message(transport, key, content, content_type \\ "text") do
    transport.adapter.send_message(transport, key, content, content_type)
  end
end
