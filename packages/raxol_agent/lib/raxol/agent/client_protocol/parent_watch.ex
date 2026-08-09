defmodule Raxol.Agent.ClientProtocol.ParentWatch do
  @moduledoc """
  Stop serving when the process that spawned us dies.

  Burrito's launcher forks the BEAM and waits, and it does not forward signals.
  Kill the launcher alone -- `Popen.terminate()` in Python, or any client that
  signals a pid rather than a process group -- and the launcher dies while the
  BEAM keeps running, holding the provider credential, with stdin still open
  because the client's end of the pipe is untouched. Nothing else notices: a
  group kill reaches the BEAM directly, and a client that exits closes the pipe
  and gives us EOF, but this case has no signal and no EOF.

  What does change is our parent. The BEAM is reparented when the launcher
  dies, so the fix is to notice that and stop.

  A slow poll is deliberate. This is a janitor for an unusual shutdown, not a
  liveness path, and the ordinary exits (EOF, group signal) are immediate and
  already handled -- so paying for a fast check here would buy nothing.
  """

  use GenServer

  require Logger

  @interval_ms 5_000

  @doc """
  Watch the current parent and run `on_orphan` when it changes.

  `:ppid_fun` reads the parent pid; the default reads `/proc/self/stat` and
  falls back to `ps` off Linux. Returns `:ignore` when the parent cannot be
  read at all, since a watchdog that cannot see its subject would otherwise
  either fire constantly or never.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @impl true
  def init(opts) do
    ppid_fun = Keyword.get(opts, :ppid_fun, &read_ppid/0)

    case ppid_fun.() do
      {:ok, ppid} ->
        {:ok,
         %{
           ppid: ppid,
           ppid_fun: ppid_fun,
           interval: Keyword.get(opts, :interval_ms, @interval_ms),
           on_orphan: Keyword.get(opts, :on_orphan, &default_orphan/0)
         }, {:continue, :arm}}

      :error ->
        :ignore
    end
  end

  @impl true
  def handle_continue(:arm, state) do
    Process.send_after(self(), :check, state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:check, state) do
    case state.ppid_fun.() do
      # Same parent, or a reading we cannot trust: keep waiting. Exiting on an
      # unreadable ppid would kill a healthy session over a transient failure.
      {:ok, ppid} when ppid == state.ppid ->
        {:noreply, state, {:continue, :arm}}

      :error ->
        {:noreply, state, {:continue, :arm}}

      {:ok, _orphaned} ->
        Logger.info("[acp] launcher exited; stopping so the BEAM does not outlive it")
        state.on_orphan.()
        {:stop, :normal, state}
    end
  end

  defp default_orphan, do: fn -> System.stop(0) end

  @doc false
  @spec read_ppid() :: {:ok, non_neg_integer()} | :error
  def read_ppid do
    case File.read("/proc/self/stat") do
      {:ok, stat} -> parse_proc_stat(stat)
      {:error, _} -> read_ppid_via_ps()
    end
  end

  # Field 4 of /proc/self/stat is the ppid, but field 2 is the command name in
  # parentheses and may itself contain spaces or parens -- so split after the
  # last ')' rather than on whitespace from the start.
  defp parse_proc_stat(stat) do
    with [_, rest] <- String.split(stat, ") ", parts: 2),
         [_state, ppid | _] <- String.split(rest, " "),
         {n, ""} <- Integer.parse(ppid) do
      {:ok, n}
    else
      _ -> :error
    end
  end

  defp read_ppid_via_ps do
    {out, status} = System.cmd("ps", ["-o", "ppid=", "-p", System.pid()], stderr_to_stdout: true)

    case {status, Integer.parse(String.trim(out))} do
      {0, {n, ""}} -> {:ok, n}
      _ -> :error
    end
  rescue
    _ -> :error
  end
end
