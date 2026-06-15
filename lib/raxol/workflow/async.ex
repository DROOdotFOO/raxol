defmodule Raxol.Workflow.Async do
  @moduledoc """
  Asynchronous execution surface for `Raxol.Workflow.Compiled` graphs.

  Wraps `Raxol.Workflow.Runtime.invoke/3` in a separately-spawned
  process and a per-run telemetry handler so callers can either:

    * fire-and-forget a run and monitor for completion
      (`async_invoke/3`), or
    * consume the run's progress as a lazy `Stream` of
      `Raxol.Core.Events.CloudEvent` structs (`stream_events/3`)

  This module ships the synchronous-spawn shape from ADR-0015. A
  `Raxol.Workflow.RunSupervisor` (DynamicSupervisor) for production
  hardening is a follow-up; the API here is supervisor-agnostic, so
  swapping to a supervised spawn does not break existing callers.

  The runtime emits telemetry events on `[:raxol, :workflow, :run, _]`
  and `[:raxol, :workflow, :node, _]`; `stream_events/3` attaches a
  handler scoped to its run_id and converts each event into a CloudEvent
  before pushing it onto the stream.
  """

  alias Raxol.Core.Events.CloudEvent
  alias Raxol.Workflow.Compiled
  alias Raxol.Workflow.Runtime

  @run_events [
    [:raxol, :workflow, :run, :started],
    [:raxol, :workflow, :run, :completed],
    [:raxol, :workflow, :run, :interrupted],
    [:raxol, :workflow, :run, :failed]
  ]

  @node_events [
    [:raxol, :workflow, :node, :started],
    [:raxol, :workflow, :node, :completed],
    [:raxol, :workflow, :node, :failed]
  ]

  @all_events @run_events ++ @node_events

  @terminal_run_kinds [:completed, :interrupted, :failed]

  @doc """
  Spawn the run in a separate process and return a handle immediately.

  Returns `{:ok, %{run_id: binary, pid: pid, ref: reference}}`. The
  caller can:

    * `Process.demonitor(ref, [:flush])` if the result is no longer
      needed.
    * `receive` `{:DOWN, ref, :process, pid, reason}` to detect
      completion.
    * subscribe to `[:raxol, :workflow, *]` telemetry events filtered
      by `run_id` for progress updates.

  The spawned process is not linked to the caller; a worker crash
  arrives as a `:DOWN` message rather than a synchronous exit signal.
  """
  @spec async_invoke(Compiled.t(), any(), keyword()) ::
          {:ok, %{run_id: binary(), pid: pid(), ref: reference()}}
  def async_invoke(%Compiled{} = compiled, initial_state, opts \\ []) do
    run_id = Runtime.generate_run_id()
    opts_with_id = Keyword.put(opts, :run_id, run_id)

    pid =
      spawn(fn ->
        Runtime.invoke(compiled, initial_state, opts_with_id)
      end)

    ref = Process.monitor(pid)
    {:ok, %{run_id: run_id, pid: pid, ref: ref}}
  end

  @doc """
  Spawn a resume in a separate process and return a handle immediately.

  Mirrors `async_invoke/3` but for the resume path. Looks up the
  latest checkpoint for `run_id` synchronously before spawning so the
  resume preconditions surface as a regular error tuple rather than
  hiding inside a normal-exit `:DOWN` message.

  Returns `{:ok, %{run_id, pid, ref}}` on success or one of:

    * `{:error, :no_saver_configured, nil}` -- graph has no Saver
    * `{:error, :no_checkpoint, nil}` -- no checkpoint for `run_id`
  """
  @spec async_resume(Compiled.t(), binary(), any(), keyword()) ::
          {:ok, %{run_id: binary(), pid: pid(), ref: reference()}}
          | {:error, :no_saver_configured | :no_checkpoint, nil}
  def async_resume(%Compiled{} = compiled, run_id, resume_value, opts \\ [])
      when is_binary(run_id) do
    case Runtime.preflight_resume(compiled, run_id) do
      {:ok, _checkpoint} ->
        pid =
          spawn(fn ->
            Runtime.resume(compiled, run_id, resume_value, opts)
          end)

        ref = Process.monitor(pid)
        {:ok, %{run_id: run_id, pid: pid, ref: ref}}

      {:error, reason} ->
        {:error, reason, nil}
    end
  end

  @doc """
  Run the graph and return a lazy `Stream` of `CloudEvent` structs.

  Each emitted telemetry event (run.started, node.started,
  node.completed, etc.) is converted to a `Raxol.Core.Events.CloudEvent`
  using the Phase 24 envelope and pushed onto the stream in the order
  the runtime emits it. The stream terminates after the first run-level
  terminal event (`completed`, `interrupted`, or `failed`).

  ## Options

    * `:timeout_ms` - per-event receive timeout (default 60_000). The
      stream halts if no event arrives within the window.
    * `:source` - CloudEvent source URI override; defaults to
      `Application.get_env(:raxol, :workflow_event_source, "raxol://workflow")`.

  Any `opts` not consumed here are forwarded to `Runtime.invoke/3`.
  """
  @spec stream_events(Compiled.t(), any(), keyword()) :: Enumerable.t()
  def stream_events(%Compiled{} = compiled, initial_state, opts \\ []) do
    Stream.resource(
      fn -> start_stream(compiled, initial_state, opts) end,
      &pull_next/1,
      &cleanup/1
    )
  end

  @doc """
  Resume a run and return a lazy `Stream` of `CloudEvent` structs.

  Mirrors `stream_events/3` but for the resume path. The stream
  carries telemetry events emitted during the resume invocation only;
  events emitted during the original (interrupted) run are not
  replayed.

  Preconditions (no saver, no checkpoint) raise `ArgumentError` from
  the stream start function rather than yielding an empty stream that
  the consumer would block on. Callers that want a tuple-shaped
  preflight should use `async_resume/4`.

  Accepts the same options as `stream_events/3`.
  """
  @spec resume_events(Compiled.t(), binary(), any(), keyword()) ::
          Enumerable.t()
  def resume_events(%Compiled{} = compiled, run_id, resume_value, opts \\ [])
      when is_binary(run_id) do
    Stream.resource(
      fn -> start_resume_stream(compiled, run_id, resume_value, opts) end,
      &pull_next/1,
      &cleanup/1
    )
  end

  # --- Stream resource lifecycle ---

  defp start_stream(compiled, initial_state, opts) do
    %{
      handler_id: handler_id,
      source: source,
      timeout_ms: timeout_ms,
      run_id: run_id
    } =
      attach_stream_handler(opts)

    runtime_opts =
      opts
      |> Keyword.put(:run_id, run_id)
      |> Keyword.drop([:timeout_ms, :source])

    pid = spawn(fn -> Runtime.invoke(compiled, initial_state, runtime_opts) end)
    ref = Process.monitor(pid)

    %{
      run_id: run_id,
      handler_id: handler_id,
      pid: pid,
      ref: ref,
      timeout_ms: timeout_ms,
      terminal_received: false
    }
  end

  defp start_resume_stream(compiled, run_id, resume_value, opts) do
    case Runtime.preflight_resume(compiled, run_id) do
      {:ok, _checkpoint} ->
        %{handler_id: handler_id, timeout_ms: timeout_ms} =
          attach_stream_handler(Keyword.put(opts, :run_id, run_id))

        runtime_opts = Keyword.drop(opts, [:timeout_ms, :source, :run_id])

        pid =
          spawn(fn ->
            Runtime.resume(compiled, run_id, resume_value, runtime_opts)
          end)

        ref = Process.monitor(pid)

        %{
          run_id: run_id,
          handler_id: handler_id,
          pid: pid,
          ref: ref,
          timeout_ms: timeout_ms,
          terminal_received: false
        }

      {:error, reason} ->
        raise ArgumentError,
              "resume_events preflight failed: #{inspect(reason)}; " <>
                "use async_resume/4 for a tuple-shaped result"
    end
  end

  defp attach_stream_handler(opts) do
    run_id = Keyword.get_lazy(opts, :run_id, &Runtime.generate_run_id/0)
    consumer_pid = self()
    handler_id = "workflow_stream_" <> run_id
    timeout_ms = Keyword.get(opts, :timeout_ms, 60_000)

    source =
      Keyword.get_lazy(opts, :source, fn ->
        Application.get_env(:raxol, :workflow_event_source, "raxol://workflow")
      end)

    :telemetry.attach_many(
      handler_id,
      @all_events,
      &handle_stream_event/4,
      %{run_id: run_id, consumer_pid: consumer_pid, source: source}
    )

    %{
      run_id: run_id,
      handler_id: handler_id,
      source: source,
      timeout_ms: timeout_ms
    }
  end

  defp pull_next(%{terminal_received: true} = state), do: {:halt, state}

  defp pull_next(state) do
    receive do
      {:workflow_stream, %CloudEvent{} = ce} ->
        {[ce], %{state | terminal_received: terminal?(ce)}}

      {:DOWN, ref, :process, pid, _reason}
      when ref == state.ref and pid == state.pid ->
        {:halt, state}
    after
      state.timeout_ms -> {:halt, state}
    end
  end

  defp cleanup(state) do
    :telemetry.detach(state.handler_id)

    Process.demonitor(state.ref, [:flush])

    if Process.alive?(state.pid) do
      Process.exit(state.pid, :kill)
    end

    :ok
  end

  defp terminal?(%CloudEvent{type: "raxol.workflow.run." <> kind}) do
    String.to_existing_atom(kind) in @terminal_run_kinds
  rescue
    ArgumentError -> false
  end

  defp terminal?(_), do: false

  # --- Telemetry -> CloudEvent ---

  defp handle_stream_event(event, measurements, metadata, config) do
    if Map.get(metadata, :run_id) == config.run_id do
      cloud_event = to_cloud_event(event, measurements, metadata, config.source)
      send(config.consumer_pid, {:workflow_stream, cloud_event})
    end
  end

  defp to_cloud_event(
         [:raxol, :workflow, scope, kind],
         measurements,
         metadata,
         source
       ) do
    type = "raxol.workflow.#{scope}.#{kind}"

    CloudEvent.new(type, source,
      data: %{measurements: measurements, metadata: metadata},
      subject: Map.get(metadata, :run_id)
    )
  end
end
