defmodule Raxol.Agent.EventForwarder do
  @moduledoc """
  Forwarding helpers for `Raxol.Agent.Stream` events.

  Orchestrators that drive an agent stream and need to relay each event
  to a parent process (terminal dashboard, LiveView, MCP surface, etc.)
  end up writing the same boilerplate:

      stream
      |> Enum.reduce_while(initial, fn event, _acc ->
        send(parent, {:run_event, key, event_to_payload(event)})
        case event do
          {:done, _info} -> {:halt, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
          _ -> {:cont, ...}
        end
      end)

  This module collapses that into one call:

      Raxol.Agent.EventForwarder.to_parent(stream, parent, key)
      #=> :ok | {:error, reason}

  ## Options

  - `:transform` (default `&Stream.Event.to_payload/1`) -- function applied
    to each event before sending. Use the identity function (`&Function.identity/1`)
    to forward raw tuples for back-compat with consumers that already
    pattern-match on the tuple shape.
  - `:tag` (default `:run_event`) -- atom tag used in the parent message.
    Final shape: `{tag, key, payload}`.
  - `:halt_on_error?` (default `true`) -- whether `{:error, _}` events
    short-circuit and return `{:error, reason}`.

  ## Return value

  - `:ok` after consuming `{:done, _}` (or stream ends)
  - `{:error, reason}` after consuming `{:error, reason}` when `halt_on_error?`
    is true
  """

  alias Raxol.Agent.Stream.Event

  @type key :: term()
  @type opts :: [
          transform: (Event.t() | tuple() -> term()),
          tag: atom(),
          halt_on_error?: boolean()
        ]

  @doc """
  Drains `stream`, forwarding each event to `parent`.

  See module docs for options.
  """
  @spec to_parent(Enumerable.t(), pid(), key(), opts()) ::
          :ok | {:error, term()}
  def to_parent(stream, parent, key, opts \\ []) when is_pid(parent) do
    transform = Keyword.get(opts, :transform, &Event.to_payload/1)
    tag = Keyword.get(opts, :tag, :run_event)
    halt_on_error? = Keyword.get(opts, :halt_on_error?, true)

    Enum.reduce_while(stream, :ok, fn event, _acc ->
      send(parent, {tag, key, transform.(event)})
      classify(event, halt_on_error?)
    end)
  end

  defp classify({:done, _info}, _halt_on_error?), do: {:halt, :ok}
  defp classify(%Event.Done{}, _halt_on_error?), do: {:halt, :ok}

  defp classify({:error, reason}, true), do: {:halt, {:error, reason}}

  defp classify(%Event.Error{reason: reason}, true),
    do: {:halt, {:error, reason}}

  defp classify({:error, _}, false), do: {:cont, :ok}
  defp classify(%Event.Error{}, false), do: {:cont, :ok}

  defp classify(_event, _halt_on_error?), do: {:cont, :ok}
end
