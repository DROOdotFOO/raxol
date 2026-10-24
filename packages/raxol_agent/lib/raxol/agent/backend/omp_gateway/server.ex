defmodule Raxol.Agent.Backend.OmpGateway.Server do
  @moduledoc """
  The process that owns the Port to `omp auth-gateway stdio`.

  The gateway is started on the first request, not at boot: the binary is
  resolved and vetted (`Raxol.Agent.Backend.OmpGateway.resolve_binary/1`)
  each time it is spawned, and requests made before its ready line wait in
  a queue. The ready line's version goes through `Raxol.Agent.OMP.Version`;
  a different major closes the port and fails every waiting caller.

  Requests are correlated by an integer id, because the gateway answers in
  completion order. Each one carries its own deadline: a caller whose
  deadline passes gets `{:error, {:gateway_timeout, ms}}`, and a reply that
  arrives for it later is dropped. When the gateway exits, every caller still
  waiting gets `{:error, {:gateway_exit, status}}` and the next request
  spawns a new one.

  One per VM by default (`Raxol.Agent.Supervisor` starts it under this
  module's name); `:name` starts a private one.
  """

  use GenServer

  require Logger

  alias Raxol.Agent.Backend.OmpGateway
  alias Raxol.Agent.Backend.OmpGateway.Codec
  alias Raxol.Agent.SpawnedPort

  @args ["auth-gateway", "stdio"]
  @default_ready_timeout_ms 15_000
  @line_bytes 65_536

  @doc """
  Start the server. Options: `:name` (default this module), `:path` (the
  `omp` binary; default the `:raxol_agent, :omp_gateway` `:path` config,
  else `PATH`), `:ready_timeout_ms` (default #{@default_ready_timeout_ms}).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Send one request and wait for its response, at most `timeout_ms` after the
  server accepts it (including any wait for the gateway to start).
  """
  @spec request(GenServer.server(), Codec.method(), String.t(), map() | nil, pos_integer()) ::
          {:ok, Codec.response()} | {:error, term()}
  def request(server, method, path, body, timeout_ms) do
    # The server answers every request by its deadline or on the gateway's
    # exit, so the call itself needs no timeout of its own.
    GenServer.call(server, {:request, method, path, body, timeout_ms}, :infinity)
  catch
    :exit, {:noproc, _} -> {:error, :gateway_not_started}
    :exit, _reason -> {:error, :gateway_down}
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       path: Keyword.get(opts, :path),
       ready_timeout_ms: Keyword.get(opts, :ready_timeout_ms, @default_ready_timeout_ms),
       port: nil,
       os_pid: nil,
       phase: :down,
       ready_timer: nil,
       buffer: [],
       next_id: 1,
       pending: %{},
       queued: []
     }}
  end

  @impl true
  def handle_call({:request, method, path, body, timeout_ms}, from, state) do
    case ensure_started(state) do
      {:ok, state} ->
        id = state.next_id
        timer = Process.send_after(self(), {:deadline, id}, timeout_ms)
        line = Codec.encode_request(id, method, path, body)

        state = %{
          state
          | next_id: id + 1,
            pending: Map.put(state.pending, id, {from, timer, timeout_ms})
        }

        {:noreply, send_or_queue(state, id, line)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({port, {:data, {:eol, chunk}}}, %{port: port} = state) do
    line = IO.iodata_to_binary([state.buffer | chunk])
    {:noreply, handle_line(line, %{state | buffer: []})}
  end

  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state),
    do: {:noreply, %{state | buffer: [state.buffer | chunk]}}

  def handle_info({port, {:exit_status, status}}, %{port: port} = state),
    do: {:noreply, gateway_down(state, {:gateway_exit, status})}

  def handle_info({:EXIT, port, reason}, %{port: port} = state),
    do: {:noreply, gateway_down(state, {:gateway_exit, reason})}

  def handle_info({:deadline, id}, state) do
    case Map.pop(state.pending, id) do
      {{from, _timer, timeout_ms}, pending} ->
        GenServer.reply(from, {:error, {:gateway_timeout, timeout_ms}})
        {:noreply, %{state | pending: pending, queued: List.keydelete(state.queued, id, 0)}}

      {nil, _pending} ->
        {:noreply, state}
    end
  end

  def handle_info(:ready_timeout, %{phase: :starting} = state) do
    kill(state)
    {:noreply, gateway_down(state, :gateway_ready_timeout)}
  end

  # A closed port's late messages and a stale timer land here.
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port), do: SpawnedPort.close(port)
  def terminate(_reason, _state), do: :ok

  defp ensure_started(%{phase: :down} = state) do
    with {:ok, path} <- OmpGateway.resolve_binary(state.path),
         {:ok, port} <- open_port(path) do
      os_pid =
        case Port.info(port, :os_pid) do
          {:os_pid, pid} -> pid
          nil -> nil
        end

      timer = Process.send_after(self(), :ready_timeout, state.ready_timeout_ms)
      {:ok, %{state | port: port, os_pid: os_pid, phase: :starting, ready_timer: timer}}
    end
  end

  defp ensure_started(state), do: {:ok, state}

  # stdin stays a pipe: requests are written to it. stderr is inherited.
  defp open_port(path) do
    opts = [:binary, :exit_status, :hide, {:line, @line_bytes}, {:args, @args}]
    {:ok, Port.open({:spawn_executable, path}, opts)}
  rescue
    error in ErlangError -> {:error, {:gateway_spawn_failed, error.original}}
  end

  defp send_or_queue(%{phase: :ready} = state, _id, line) do
    write(state.port, line)
    state
  end

  # Newest first; flushed in reverse, so in arrival order.
  defp send_or_queue(state, id, line), do: %{state | queued: [{id, line} | state.queued]}

  # A gateway that has just exited may have closed the port before its exit
  # status is handled; that status still arrives and fails the caller.
  defp write(port, line) do
    Port.command(port, line)
  rescue
    ArgumentError -> :ok
  end

  defp handle_line(line, %{phase: :starting} = state) do
    cancel(state.ready_timer)

    case Codec.decode_ready(line) do
      {:ok, _version, warnings} ->
        Enum.each(warnings, &warn/1)

        state.queued
        |> Enum.reverse()
        |> Enum.each(fn {_id, queued} -> write(state.port, queued) end)

        %{state | phase: :ready, ready_timer: nil, queued: []}

      {:error, reason} ->
        SpawnedPort.close(state.port)
        gateway_down(state, {:gateway_refused, reason})
    end
  end

  defp handle_line(line, %{phase: :ready} = state) do
    with {:ok, %{id: id} = response} <- Codec.decode_response(line),
         {{from, timer, _timeout_ms}, pending} <- Map.pop(state.pending, id) do
      cancel(timer)
      GenServer.reply(from, {:ok, response})
      %{state | pending: pending}
    else
      # A reply to a caller whose deadline already passed.
      {nil, _pending} ->
        state

      {:error, :invalid_response} ->
        Logger.warning("omp auth-gateway: dropped a line that is not a response")
        state
    end
  end

  defp gateway_down(state, reason) do
    cancel(state.ready_timer)

    Enum.each(state.pending, fn {_id, {from, timer, _timeout_ms}} ->
      cancel(timer)
      GenServer.reply(from, {:error, reason})
    end)

    %{
      state
      | port: nil,
        os_pid: nil,
        phase: :down,
        ready_timer: nil,
        buffer: [],
        pending: %{},
        queued: []
    }
  end

  # A gateway that never printed its ready line is not reading stdin either,
  # so closing the port would leave it running.
  defp kill(%{port: port, os_pid: os_pid}) do
    with pid when is_integer(pid) <- os_pid,
         kill when is_binary(kill) <- System.find_executable("kill") do
      System.cmd(kill, ["-9", Integer.to_string(pid)], stderr_to_stdout: true)
    end

    SpawnedPort.close(port)
  end

  defp warn({:newer_minor, found, tested}),
    do: Logger.warning("omp #{found} is newer than the tested #{tested}; continuing")

  defp cancel(nil), do: :ok
  defp cancel(timer), do: Process.cancel_timer(timer)
end
