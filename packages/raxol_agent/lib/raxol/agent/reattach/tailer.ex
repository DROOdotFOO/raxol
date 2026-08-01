defmodule Raxol.Agent.Reattach.Tailer do
  @moduledoc """
  Read-side live tail for a reattached session (U4, AD-15/FI-12). One process
  per attach: it re-scans the session journal on a short interval and forwards
  each new durable record to the attaching process as
  `{:reattach_live, session_id, record}` in offset order, exactly once.

  It is purely a reader — it never appends — so it is safe against a writerless
  session (dead BEAM / tar'd / replay-only) and cannot deliver a not-yet-durable
  id: it only ever observes records already framed on disk, so the I3
  publish-ahead window (N-JS7) is closed by construction.

  The tailer monitors the attaching process and stops when that process exits,
  so a reattachment never outlives its client. The scan interval is
  `config :raxol_agent, :reattach_poll_ms` (default 20ms).
  """

  use GenServer

  alias Raxol.Agent.Journal.FileStore.Reader

  @default_poll_ms 20

  @doc """
  Start a tailer delivering durable records with id `>= from_offset` from `dir`
  to `caller`. Returns `{:ok, pid}` — the pid is the `live` handle in the
  reattach result. The tailer stops itself when `caller` exits; `stop/1` ends it
  early.
  """
  @spec start(Path.t(), String.t(), non_neg_integer(), pid()) :: {:ok, pid()}
  def start(dir, session_id, from_offset, caller)
      when is_integer(from_offset) and from_offset >= 0 and is_pid(caller) do
    GenServer.start(__MODULE__, {dir, session_id, from_offset, caller})
  end

  @doc "Stop a tailer early."
  @spec stop(pid()) :: :ok
  def stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid), else: :ok
  end

  @impl GenServer
  def init({dir, session_id, from_offset, caller}) do
    monitor_ref = Process.monitor(caller)

    state = %{
      dir: dir,
      session_id: session_id,
      caller: caller,
      monitor_ref: monitor_ref,
      last_id: from_offset - 1,
      interval: Application.get_env(:raxol_agent, :reattach_poll_ms, @default_poll_ms)
    }

    # Deliver the catch-up tail on the first tick, then follow future appends.
    send(self(), :poll)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    state = deliver_new(state)
    Process.send_after(self(), :poll, state.interval)
    {:noreply, state}
  end

  # The attaching process is gone; a reattachment must not outlive its client.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor_ref: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Deliver every durable record newer than the cursor, in ascending offset
  # order, advancing the cursor so no record is ever delivered twice and none is
  # skipped. A damaged scan delivers nothing this tick (never a partial or
  # out-of-order tail) and the next tick retries.
  defp deliver_new(state) do
    case Reader.scan(state.dir) do
      {:ok, records} ->
        records
        |> Enum.filter(fn %{"id" => id} -> id > state.last_id end)
        |> Enum.sort_by(fn %{"id" => id} -> id end)
        |> Enum.reduce(state, fn record, acc ->
          send(acc.caller, {:reattach_live, acc.session_id, record})
          %{acc | last_id: record["id"]}
        end)

      {:damaged, _partial} ->
        state
    end
  end
end
