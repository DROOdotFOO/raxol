defmodule Raxol.Core.Runtime.EmitBus do
  @moduledoc """
  Lightweight, package-neutral pub/sub for TEA runtime events.

  This is the **keystone seam** for the harness event stream. The Dispatcher
  publishes one neutral event map at each of its two model-fold sites
  (`process_app_update/3` and `process_command_result/3`); any process that
  subscribes by `session_id` receives those maps as `{:emit_bus, session_id,
  event}` messages.

  The bus deliberately knows nothing about the agent contract. It carries a
  plain map so the **main `raxol` package never depends on `raxol_agent`**
  (a back-dep would be circular). The `raxol_agent` side subscribes via
  `Raxol.Agent.EmitBridge`, translates each neutral map into a
  `Raxol.Agent.Contract.Event`, and re-emits it through
  `Raxol.Agent.SessionStreamer`. Producer (Dispatcher) and consumer
  (agent surfaces) meet only at this map shape.

  ## Neutral event shape

      %{
        session_id: term(),
        family: :loop | :meta,
        type: atom(),
        tier: :ephemeral | :durable,
        turn_id: String.t() | nil,
        payload: map(),
        ts: integer()   # System.system_time(:microsecond)
      }

  ## Transport

  A `:duplicate`-keyed `Registry` keyed by `session_id`. It is started as part
  of the application supervision tree (see `Raxol.Application`). When the
  registry is not running (e.g. a minimal/headless boot), `subscribe/1`,
  `unsubscribe/1`, and `publish/1` degrade to `:ok` no-ops rather than crash —
  matching the resilience of `Dispatcher.broadcast/2`.
  """

  @registry __MODULE__.Registry

  @type tier :: :ephemeral | :durable
  @type family :: :loop | :meta

  @type event :: %{
          session_id: term(),
          family: family(),
          type: atom(),
          tier: tier(),
          turn_id: String.t() | nil,
          payload: map(),
          ts: integer()
        }

  @doc """
  Child spec for the backing registry. Add `Raxol.Core.Runtime.EmitBus` to a
  supervision tree to start it.
  """
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    Registry.child_spec(keys: :duplicate, name: @registry)
  end

  @doc "The registered name of the backing registry."
  @spec registry_name() :: atom()
  def registry_name, do: @registry

  @doc """
  Subscribe the calling process to events for `session_id`.

  Events arrive as `{:emit_bus, session_id, event}` messages. No-ops when the
  registry is not running.
  """
  @spec subscribe(term()) :: :ok
  def subscribe(session_id) do
    _ = Registry.register(@registry, session_id, nil)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Unsubscribe the calling process from `session_id`."
  @spec unsubscribe(term()) :: :ok
  def unsubscribe(session_id) do
    _ = Registry.unregister(@registry, session_id)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Publish a neutral `event` to every subscriber of its `session_id`.

  No-ops when the registry is not running.
  """
  @spec publish(event()) :: :ok
  def publish(%{session_id: session_id} = event) do
    Registry.dispatch(@registry, session_id, fn entries ->
      Enum.each(entries, fn {pid, _value} ->
        send(pid, {:emit_bus, session_id, event})
      end)
    end)

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Build a neutral event map.

  Options: `:family` (default `:loop`) and `:turn_id` (default `nil`). `ts` is
  stamped at build time.
  """
  @spec build(term(), atom(), tier(), map(), keyword()) :: event()
  def build(session_id, type, tier, payload, opts \\ [])
      when is_atom(type) and tier in [:ephemeral, :durable] and is_map(payload) do
    %{
      session_id: session_id,
      family: Keyword.get(opts, :family, :loop),
      type: type,
      tier: tier,
      turn_id: Keyword.get(opts, :turn_id),
      payload: payload,
      ts: System.system_time(:microsecond)
    }
  end
end
