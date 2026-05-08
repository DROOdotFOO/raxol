defmodule Raxol.Symphony.Surfaces.Watch.Notifier do
  @moduledoc """
  Subscribes to a `Raxol.Symphony.Orchestrator` and delivers Watch
  notifications via a pluggable backend.

  ## Backends

  The default backend is `Raxol.Watch.Notifier.push_to_all/1` (broadcasts
  to every device registered with `Raxol.Watch.DeviceRegistry`). When
  `raxol_watch` is not loaded, sends are dropped after a single startup
  warning.

  Pass `:push_fn` for tests:

      Notifier.start_link(
        orchestrator: orch,
        push_fn: fn notif -> send(parent, {:pushed, notif}); :ok end
      )

  ## Priority bypass

  `:high`-priority notifications bypass any debounce in the underlying
  watch backend (preflight failures are operator-blocking). Other
  priorities go through the backend's normal pipeline.

  ## Action callbacks

  Notification action ids use the `sym:<verb>[:<arg>]` namespace.
  `handle_action/2` is exposed as a thin convenience that maps inbound
  action callbacks back to orchestrator commands; the host application is
  free to wire it directly to `raxol_watch`'s ActionHandler or call it
  from any other context.
  """

  use GenServer
  require Logger

  alias Raxol.Symphony.Orchestrator
  alias Raxol.Symphony.Surfaces.Watch.Formatter

  @compile {:no_warn_undefined, [Raxol.Watch.Notifier]}

  @type push_fn :: (Formatter.notification() -> any())

  @type state :: %{
          orchestrator: GenServer.server(),
          push_fn: push_fn()
        }

  # -- Public API -------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Force a snapshot push. Useful for `/status` style commands."
  @spec push_snapshot(GenServer.server()) :: :ok
  def push_snapshot(server \\ __MODULE__) do
    GenServer.cast(server, :push_snapshot)
  end

  @doc "Returns the current configuration. Test introspection."
  @spec config(GenServer.server()) :: state()
  def config(server \\ __MODULE__) do
    GenServer.call(server, :config)
  end

  @doc """
  Maps an inbound action id to an orchestrator command. Returns the command
  taken, or `:noop` for `sym:dismiss` and unknown ids.

  This is a pure helper -- it does not consult any GenServer state -- so
  routers can call it directly:

      Watch.Notifier.handle_action("sym:stop:iss_42", orchestrator: my_orch)
  """
  @spec handle_action(String.t(), keyword()) ::
          {:ok, atom()} | {:error, term()} | :noop
  def handle_action(action_id, opts \\ []) when is_binary(action_id) do
    orch = Keyword.get(opts, :orchestrator, Raxol.Symphony.Orchestrator)

    action_id
    |> String.split(":")
    |> dispatch_action(orch)
  end

  defp dispatch_action(["sym", "refresh"], orch), do: do_refresh(orch)
  defp dispatch_action(["sym", "stop", id], orch), do: do_stop(orch, id)
  defp dispatch_action(["sym", "approve", _id], orch), do: do_approve(orch)
  defp dispatch_action(["sym", "approve"], orch), do: do_approve(orch)
  defp dispatch_action(["sym", "dismiss"], _orch), do: :noop
  defp dispatch_action(_, _orch), do: :noop

  defp do_refresh(orch) do
    _ = safe_call(fn -> Orchestrator.refresh(orch) end)
    {:ok, :refresh}
  end

  defp do_approve(orch) do
    _ = safe_call(fn -> Orchestrator.refresh(orch) end)
    {:ok, :approve_acknowledged}
  end

  defp do_stop(orch, id) do
    case safe_call(fn -> Orchestrator.stop_run(orch, id) end) do
      {:ok, :ok} -> {:ok, :stopped}
      {:ok, {:error, reason}} -> {:error, reason}
      _ -> {:error, :orchestrator_unavailable}
    end
  end

  # -- GenServer callbacks ----------------------------------------------------

  @impl true
  def init(opts) do
    orch = Keyword.get(opts, :orchestrator, Raxol.Symphony.Orchestrator)
    push_fn = Keyword.get(opts, :push_fn, &default_push/1)

    state = %{orchestrator: orch, push_fn: push_fn}

    case safe_call(fn -> Orchestrator.subscribe(orch) end) do
      {:ok, :ok} ->
        :ok

      _ ->
        Logger.warning(
          "symphony.watch.subscribe_failed orchestrator=#{inspect(orch)}"
        )
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:config, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast(:push_snapshot, state) do
    snapshot = safe_snapshot(state.orchestrator)
    push(state, Formatter.snapshot_notification(snapshot))
    {:noreply, state}
  end

  @impl true
  def handle_info({:symphony_event, name, snapshot}, state) do
    case Formatter.event_notification(name, snapshot) do
      :skip ->
        :ok

      notification ->
        push(state, notification)
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Internals --------------------------------------------------------------

  defp push(%{push_fn: push_fn}, notification) do
    push_fn.(notification)
  catch
    kind, reason ->
      Logger.warning(
        "symphony.watch.push_failed kind=#{inspect(kind)} reason=#{inspect(reason)}"
      )
  end

  defp safe_snapshot(orch) do
    case safe_call(fn -> Orchestrator.snapshot(orch) end) do
      {:ok, %{} = snap} -> snap
      _ -> %{counts: %{running: 0, retrying: 0}, running: [], retrying: []}
    end
  end

  defp safe_call(fun) do
    {:ok, fun.()}
  catch
    :exit, _ -> :error
    :error, _ -> :error
  end

  defp default_push(notification) do
    if Code.ensure_loaded?(Raxol.Watch.Notifier) do
      Raxol.Watch.Notifier.push_to_all(notification)
    else
      Logger.debug("symphony.watch.push_skipped (raxol_watch not loaded)")
      :ok
    end
  end
end
